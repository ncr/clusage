"""clusage_api -- shared access to the Claude Code usage endpoint.

Reads the OAuth token Claude Code stores in ~/.claude/.credentials.json,
refreshes it when expired (writing it back the same way the CLI does), and
calls the undocumented endpoint the `/usage` panel uses:

    GET https://api.anthropic.com/api/oauth/usage

Used by both `clusage-waybar` (the bar module) and `clusage-warmup` (the daily
session anchor). Scripts import this by realpath so it keeps working when they
are invoked through a symlink on PATH.
"""

import json
import os
import time
import urllib.request
import urllib.error
from datetime import datetime, timedelta

CREDS_PATH = os.path.expanduser("~/.claude/.credentials.json")
CACHE_DIR = os.path.expanduser("~/.cache/clusage")
CACHE_PATH = os.path.join(CACHE_DIR, "usage.json")

API_BASE = "https://api.anthropic.com"
USAGE_URL = f"{API_BASE}/api/oauth/usage"
TOKEN_URL = f"{API_BASE}/v1/oauth/token"
# Public Claude Code OAuth client id (same one the CLI ships).
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

UA = "clusage/1.0"

# Length of a Claude Code rate-limit session block.
SESSION_HOURS = 5


def _http_json(req, timeout=8):
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def load_creds():
    with open(CREDS_PATH) as f:
        return json.load(f)


def save_creds(data):
    """Atomically write credentials back, preserving permissions (0600)."""
    tmp = CREDS_PATH + ".clusage.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
    except Exception:
        try:
            os.unlink(tmp)
        finally:
            raise
    os.replace(tmp, CREDS_PATH)


def refresh_token(creds):
    """Refresh the access token in place and persist it. Returns new access token."""
    oauth = creds["claudeAiOauth"]
    body = json.dumps(
        {
            "grant_type": "refresh_token",
            "refresh_token": oauth["refreshToken"],
            "client_id": CLIENT_ID,
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        TOKEN_URL,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "User-Agent": UA,
            "anthropic-beta": "oauth-2025-04-20",
        },
    )
    tok = _http_json(req)
    oauth["accessToken"] = tok["access_token"]
    if tok.get("refresh_token"):
        oauth["refreshToken"] = tok["refresh_token"]
    if tok.get("expires_in"):
        oauth["expiresAt"] = int(time.time() * 1000) + int(tok["expires_in"]) * 1000
    save_creds(creds)
    return oauth["accessToken"]


def get_access_token():
    creds = load_creds()
    oauth = creds["claudeAiOauth"]
    expires_at = oauth.get("expiresAt", 0)
    # Refresh if expired or within 60s of expiry.
    if time.time() * 1000 >= expires_at - 60_000:
        return refresh_token(creds)
    return oauth["accessToken"]


def fetch_usage(token=None, allow_refresh=True):
    if token is None:
        token = get_access_token()
    req = urllib.request.Request(
        USAGE_URL,
        method="GET",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": UA,
            "anthropic-beta": "oauth-2025-04-20",
        },
    )
    try:
        return _http_json(req)
    except urllib.error.HTTPError as e:
        if e.code == 401 and allow_refresh:
            # Token rejected -> force a refresh and retry once.
            creds = load_creds()
            token = refresh_token(creds)
            return fetch_usage(token, allow_refresh=False)
        raise


def fetch_usage_retry(attempts=3, delay=5):
    """fetch_usage with backoff -- the endpoint 429s easily under repeat calls.

    Only worth it for one-shot callers (clusage-warmup); the bar module prefers
    its stale cache over blocking for seconds.
    """
    last = None
    for i in range(attempts):
        try:
            return fetch_usage()
        except Exception as e:  # noqa: PERF203 -- retry loop
            last = e
            if i < attempts - 1:
                time.sleep(delay * (i + 1))
    raise last


def write_cache(usage):
    os.makedirs(CACHE_DIR, exist_ok=True)
    payload = {"fetched_at": int(time.time()), "usage": usage}
    tmp = CACHE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(payload, f)
    os.replace(tmp, CACHE_PATH)


def read_cache():
    try:
        with open(CACHE_PATH) as f:
            return json.load(f)
    except Exception:
        return None


def pct(block):
    # The API returns utilization already as a percentage (e.g. 32.0 == 32%).
    if not block:
        return None
    return block.get("utilization")


def parse_iso(iso):
    """ISO-8601 string -> local-time datetime rounded to the minute, or None.

    Block boundaries are on the hour, but the API jitters either side of it
    ("13:00:00.97" one call, "12:59:59.95" the next). Truncating the second one
    renders a 15:00 reset as "14:59", so round instead.
    """
    if not iso:
        return None
    try:
        dt = datetime.fromisoformat(iso).astimezone()
    except Exception:
        return None
    return (dt + timedelta(seconds=30)).replace(second=0, microsecond=0)


def fmt_iso(iso, weekly=False):
    dt = parse_iso(iso)
    if dt is None:
        return ""
    return dt.strftime("%a %H:%M") if weekly else dt.strftime("%H:%M")


def time_until(block):
    """Compact countdown until this block resets, e.g. '2h18m', '47m', 'now'."""
    dt = parse_iso((block or {}).get("resets_at"))
    if dt is None:
        return ""
    secs = int(dt.timestamp() - time.time())
    if secs <= 0:
        return "now"
    h, m = divmod(secs // 60, 60)
    if h:
        return f"{h}h{m:02d}m"
    return f"{m}m"


def session_window(usage):
    """The current 5h session block as (start, end) local datetimes, or (None, None).

    The API only reports when the block resets; blocks are five hours long and
    start on the hour, so the start is simply reset - 5h.
    """
    end = parse_iso((usage.get("five_hour") or {}).get("resets_at"))
    if end is None:
        return None, None
    return end - timedelta(hours=SESSION_HOURS), end


def session_is_active(usage):
    """True if a 5h session block is currently running (and has been used).

    A block that reports 0% utilization is treated as not started: re-anchoring
    it costs one tiny request and is what the caller wants anyway.
    """
    five = usage.get("five_hour") or {}
    _, end = session_window(usage)
    if end is None:
        return False
    return (five.get("utilization") or 0) > 0 and end.timestamp() > time.time()
