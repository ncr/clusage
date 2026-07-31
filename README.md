# clusage — Claude Code usage in the Omarchy bar

Two small tools around the Claude Code rate limits:

- **`clusage-waybar`** — a Waybar module showing live utilization in the top bar.
- **`clusage-warmup`** — a daily hello that makes the 5h session limit reset at 12:00.

## clusage-waybar — the indicator

Shows your live Claude Code rate-limit utilization in the Omarchy top bar — the
same numbers as the `/usage` panel.

- **Bar text:** `󰚩 {session}%·{weekly}%·{F}{fable}% 󰅐 {countdown}` — session (5h) and
  weekly (all-models) utilization, any **active per-model weekly cap** abbreviated by
  initial (e.g. `F100%` for Fable at its weekly limit), plus time until the session
  window resets (e.g. `4h20m`).
- **Tooltip (hover):** session + weekly with reset times, the **per-model weekly caps**
  (Fable, and Sonnet/Opus if the API still reports them) with `◀` marking the currently
  binding one, and overage-credit usage.
- Refreshes every 60s. Color shifts amber → red as utilization climbs; dims when stale.

## How it works

`clusage-waybar` reads the OAuth token Claude Code stores in
`~/.claude/.credentials.json` (`claudeAiOauth`), refreshes it via
`https://api.anthropic.com/v1/oauth/token` when expired (writing the new token
back atomically, same as the CLI does), and calls the usage endpoint the
`/usage` panel uses:

    GET https://api.anthropic.com/api/oauth/usage   (Bearer token)

Successful responses are cached to `~/.cache/clusage/usage.json`; if a fetch
fails, the last value is shown dimmed (class `stale`) instead of going blank.

### Response notes (undocumented endpoint)
- `utilization` is **already a percentage** (e.g. `32.0` == 32%), not a 0–1 fraction.
- `resets_at` is an ISO-8601 string, and it **jitters around the hour boundary**
  (`13:00:00.97` one call, `12:59:59.95` the next) — round to the minute or a
  15:00 reset renders as `14:59`.
- Blocks can be `null` (e.g. `seven_day_opus` when Opus is unused this week).
- **Per-model weekly caps moved into `limits[]`**: the old `seven_day_<model>` fields
  are now `null`; each model cap is a `weekly_scoped` entry carrying
  `scope.model.display_name` (e.g. `Fable`), a `percent`, and `is_active` marking the
  currently binding limit.

## clusage-warmup — make the session limit reset at 12:00

Rate limits run in **5-hour session blocks that start at the top of the hour you
send your first message in** and reset five hours later. So the reset time is
decided by when you first say hello: a first message at 07:15 gives a 07:00–12:00
block that resets at noon, one at 09:40 pushes the reset out to 14:00.

`clusage-warmup` sends that first message for you at **07:00** so the limit is
reset and waiting at noon. It's one Haiku request with `--safe-mode --tools ""`
and a one-line system prompt — ~170 input tokens, ~3s, well under a cent. Enough
to open the block, nothing more.

```bash
clusage-warmup                 # what the timer runs (guards apply)
clusage-warmup --force         # warm up now, whatever the clock says
clusage-warmup --reset-at 14   # aim for a 14:00 reset (so, hello at 09:00)
clusage-warmup --hello-at 8    # say hello at 08:00 whatever that resets to
clusage-warmup --model sonnet  # default: haiku
```

Two guards, both bypassed by `--force`:

- **Outside the hello hour it does nothing.** Blocks start on the hour, so a
  missed-timer catch-up at 07:45 still resets at 12:00 — but one at 11:00 would
  push the reset to 16:00, which is worse than not running at all.
- **A running block is left alone.** If you were already working at 06:00, the
  hello lands inside that window and changes nothing; it's skipped, and the log
  says what the reset actually is (`resets 11:00, not 12:00`).

The session state comes from `~/.cache/clusage/usage.json` when Waybar refreshed
it in the last 90s, so the usual run costs no extra API call. Afterwards it
reports the window it opened, notifies via `notify-send`, and signals Waybar to
redraw. Logs go to the journal:

```bash
journalctl --user -u clusage-warmup -n 20
systemctl --user list-timers clusage-warmup.timer
```

Change the time by editing `OnCalendar=` in `systemd/clusage-warmup.timer` **and**
`CLUSAGE_RESET_HOUR` in the service — the script derives its hello hour from the
reset hour (minus 5) and refuses to run outside it, so the two must agree
(`CLUSAGE_RESET_HOUR=12` ⇒ `OnCalendar=*-*-* 07:00:00`) or every run skips itself.

## Installed files

| File | Purpose |
|------|---------|
| `~/dev/clusage/clusage_api.py` | shared OAuth + usage-endpoint access |
| `~/dev/clusage/clusage-waybar` | the bar module (source of truth) |
| `~/dev/clusage/clusage-warmup` | the daily session warm-up |
| `~/dev/clusage/systemd/clusage-warmup.{service,timer}` | 07:00 daily timer (⇒ 12:00 reset) |
| `~/.local/bin/clusage-{waybar,warmup}` | symlinks onto `PATH` |
| `~/.config/systemd/user/clusage-warmup.{service,timer}` | symlinks (`systemctl --user link`) |
| `~/.config/waybar/config.jsonc` | `custom/clusage` module + `modules-right` entry |
| `~/.config/waybar/style.css` | `#custom-clusage` spacing + severity colors |
| `~/.cache/clusage/usage.json` | last successful response |

Click the module to force a refresh; right-click for a notification with the full breakdown.

Install the timer with:

```bash
ln -sfn ~/dev/clusage/clusage-warmup ~/.local/bin/clusage-warmup
systemctl --user link ~/dev/clusage/systemd/clusage-warmup.{service,timer}
systemctl --user enable --now clusage-warmup.timer
```

## Caveats

- Uses the CLI's own undocumented OAuth endpoint — Anthropic could change it.
- The endpoint **429s easily** under repeated calls; the bar falls back to its
  stale cache and the warm-up backs off, then reports the window it expects.
- The timer can't wake a sleeping machine (user timers lack `WakeSystem=`). If
  the box is asleep at 07:00, the catch-up run only warms up when it wakes
  during the 07:00 hour — otherwise the day's reset falls wherever your first
  real message lands.
- The 07:00–12:00 block is sacrificial by design: morning usage goes into it and
  a fresh limit is waiting at noon.
- The script can refresh the OAuth token and rewrite `~/.claude/.credentials.json`.
  Because refresh tokens rotate, the new token is written back to the same file
  Claude Code reads, so the CLI picks it up on next use. It only refreshes when
  the token is within 60s of expiry (or on a 401).

## Remove

```bash
systemctl --user disable --now clusage-warmup.timer
rm ~/.config/systemd/user/clusage-warmup.{service,timer}
systemctl --user daemon-reload
rm ~/.local/bin/clusage-{waybar,warmup}
rm -rf ~/.cache/clusage
# then delete the custom/clusage module + modules-right entry from
# ~/.config/waybar/config.jsonc and the #custom-clusage rules from style.css
omarchy restart waybar
```
