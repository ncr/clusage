# clusage — Claude Code usage in your top bar

Small tools around the Claude Code rate limits:

- **`shell/io.github.ncr.clusage`** — an Omarchy shell plugin: the pill in the bar,
  and a panel with every limit when you click it.
- **`clusage-swiftbar`** — the same indicator for the macOS menu bar, via [SwiftBar](https://github.com/swiftbar/SwiftBar).
- **`clusage-waybar`** — the script behind both. `--panel` prints the bar text and the
  limits as one JSON object; without it, the older Waybar module format.
- **`clusage-warmup`** — a daily hello that makes the 5h session limit reset at 12:00 (Linux, systemd timer).

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

## The Omarchy plugin

`shell/io.github.ncr.clusage/` is a bar widget for the Omarchy shell (Quickshell),
not for Waybar. `Panel.qml` calls `clusage-waybar --panel` once per refresh and
draws both the pill and the panel from that one answer, so opening the panel costs
no extra request — the endpoint returns 429 readily.

Install it by symlinking the directory into the plugins directory, then add
`{"id": "io.github.ncr.clusage"}` to a bar section in `~/.config/omarchy/shell.json`:

```bash
ln -s ~/dev/clusage/shell/io.github.ncr.clusage ~/.config/omarchy/plugins/io.github.ncr.clusage
omarchy restart shell
```

Two settings live in the `shell.json` entry: `refreshIntervalSec` (default 60, floor 15)
and `command` (path to `clusage-waybar`).

## clusage-swiftbar — the macOS menu bar

[SwiftBar](https://github.com/swiftbar/SwiftBar) is the macOS analog to Waybar —
it hosts scripts as menu-bar items. `clusage-swiftbar` renders:

- **Menu-bar title:** `◔ {session}% {M}{model}%` — e.g. `◔ 85% F90%`, where the
  second figure is the Fable weekly limit (`F` = Fable; falls back to the highest
  per-model limit if Fable isn't active). A plain Unicode glyph is used so it
  renders without a Nerd Font; weekly-all lives in the dropdown.
- **Dropdown (click):** every limit — session (with countdown), weekly (all), and each
  active per-model weekly limit with reset times; a `●` marks the model you're
  currently constrained by. Plus overage credits (if enabled), a **Refresh** action,
  and — when the value is stale — the reason the last fetch failed.

### Install

```bash
./install-macos.sh
```

This installs SwiftBar (via Homebrew if missing), symlinks the plugin into
`~/.config/swiftbar/plugins/clusage.60s.py` (the repo stays the source of truth —
edits take effect on the next refresh), and installs a LaunchAgent
(`~/Library/LaunchAgents/com.clusage.swiftbar.plist`) so SwiftBar **autostarts at
login** and the indicator is always in the top bar. Re-run it any time to pick up
edits. Uninstall with `./uninstall-macos.sh`.

> Alternatively, remove the LaunchAgent and use SwiftBar Preferences → *Launch at
> Login* for the native login-item mechanism.

If the item vanishes from the bar, check it hasn't been disabled inside SwiftBar
(`defaults read com.ameba.SwiftBar DisabledPlugins`); re-enable with
`open -g "swiftbar://enableplugin?name=clusage"`.

## How it works

The scripts read the OAuth token Claude Code stores (`claudeAiOauth`), refresh
it via `https://api.anthropic.com/v1/oauth/token` when expired (writing the new
token back to the same place, same as the CLI does), and call the usage endpoint
the `/usage` panel uses:

    GET https://api.anthropic.com/api/oauth/usage   (Bearer token)

Where the token lives:

- **Linux:** `~/.claude/.credentials.json` (`clusage_api.py`).
- **macOS:** the login Keychain, item `Claude Code-credentials` (account = your
  username), holding the same JSON blob. Newer CLIs (2.1.x+) moved it there and
  leave `~/.claude/.credentials.json` as a stub with **empty** tokens, so
  `clusage-swiftbar` reads the Keychain first (via `/usr/bin/security`, the same
  tool the CLI uses, so no access prompt) and only falls back to the file if the
  Keychain has no usable token.

Successful responses are cached to `~/.cache/clusage/usage.json`; if a fetch
fails, the last value is shown dimmed (class `stale`) instead of going blank.

### Response notes (undocumented endpoint)
- `utilization` (and `limits[].percent`) is **already a percentage** (e.g. `32.0` == 32%),
  not a 0–1 fraction.
- `resets_at` is an ISO-8601 string, and it **jitters around the hour boundary**
  (`13:00:00.97` one call, `12:59:59.95` the next) — round to the minute or a
  15:00 reset renders as `14:59`.
- Blocks can be `null` (e.g. `seven_day_opus` when Opus is unused this week).
- **Per-model weekly caps moved into `limits[]`**: the old `seven_day_<model>` fields
  are now `null`; each entry is `{kind, percent, resets_at, scope, is_active}` with
  `kind` one of `session`, `weekly_all`, or `weekly_scoped` — the latter carries
  `scope.model.display_name` (e.g. `Fable`) and `is_active` marks the currently
  binding limit.

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

**Linux (Omarchy shell + warm-up)**

| File | Purpose |
|------|---------|
| `~/dev/clusage/clusage_api.py` | shared OAuth + usage-endpoint access |
| `~/dev/clusage/clusage-waybar` | fetches the numbers; `--panel` feeds the plugin |
| `~/dev/clusage/shell/io.github.ncr.clusage/` | the Omarchy bar widget (symlinked into `~/.config/omarchy/plugins/`) |
| `~/dev/clusage/clusage-warmup` | the daily session warm-up |
| `~/dev/clusage/systemd/clusage-warmup.{service,timer}` | 07:00 daily timer (⇒ 12:00 reset) |
| `~/.local/bin/clusage-{waybar,warmup}` | symlinks onto `PATH` |
| `~/.config/systemd/user/clusage-warmup.{service,timer}` | symlinks (`systemctl --user link`) |
| `~/.config/omarchy/shell.json` | the `io.github.ncr.clusage` entry in a bar section |
| `~/.cache/clusage/usage.json` | last successful response |

Click the pill to open the panel; it refetches only when the last fetch is older than 30 s.

Install the timer with:

```bash
ln -sfn ~/dev/clusage/clusage-warmup ~/.local/bin/clusage-warmup
systemctl --user link ~/dev/clusage/systemd/clusage-warmup.{service,timer}
systemctl --user enable --now clusage-warmup.timer
```

**macOS (SwiftBar)**

| File | Purpose |
|------|---------|
| `~/dev/clusage/clusage-swiftbar` | the plugin (source of truth; self-contained, Keychain-aware copy of the core) |
| `~/.config/swiftbar/plugins/clusage.60s.py` | symlink SwiftBar runs every 60s |
| `~/Library/LaunchAgents/com.clusage.swiftbar.plist` | autostart SwiftBar at login |
| `~/.cache/clusage/usage.json` | last successful response |

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
- The scripts can refresh the OAuth token and rewrite the credential store
  (`~/.claude/.credentials.json` on Linux, the `Claude Code-credentials` Keychain
  item on macOS). Because refresh tokens rotate, the new token is written back to
  the same place Claude Code reads, so the CLI picks it up on next use. It only
  refreshes when the token is within 60s of expiry (or on a 401).

## Remove

**Linux**

```bash
systemctl --user disable --now clusage-warmup.timer
rm ~/.config/systemd/user/clusage-warmup.{service,timer}
systemctl --user daemon-reload
rm ~/.local/bin/clusage-{waybar,warmup}
rm -rf ~/.cache/clusage
rm ~/.config/omarchy/plugins/io.github.ncr.clusage
# then delete the io.github.ncr.clusage entry from ~/.config/omarchy/shell.json
omarchy restart shell
```

**macOS**

```bash
./uninstall-macos.sh            # removes the plugin, LaunchAgent, and cache
brew uninstall --cask swiftbar  # optional: remove SwiftBar itself
```
