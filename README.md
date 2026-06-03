# clusage — Claude Code usage indicator for Waybar

A Waybar module that shows your live Claude Code rate-limit utilization in the
Omarchy top bar — the same numbers as the `/usage` panel.

- **Bar text:** `󰚩 {session}%·{weekly}% 󰅐 {countdown}` — session (5h) and weekly
  (all-models) utilization, plus time until the session window resets (e.g. `4h20m`).
- **Tooltip (hover):** session + weekly with reset times, **Sonnet** (and Opus, if active)
  weekly breakdown, and overage-credit usage.
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
- `resets_at` is an ISO-8601 string.
- Blocks can be `null` (e.g. `seven_day_opus` when Opus is unused this week).

## Installed files

| File | Purpose |
|------|---------|
| `~/dev/clusage/clusage-waybar` | the script (source of truth) |
| `~/.local/bin/clusage-waybar` | symlink onto `PATH` |
| `~/.config/waybar/config.jsonc` | `custom/clusage` module + `modules-right` entry |
| `~/.config/waybar/style.css` | `#custom-clusage` spacing + severity colors |
| `~/.cache/clusage/usage.json` | last successful response |

Click the module to force a refresh; right-click for a notification with the full breakdown.

## Caveats

- Uses the CLI's own undocumented OAuth endpoint — Anthropic could change it.
- The script can refresh the OAuth token and rewrite `~/.claude/.credentials.json`.
  Because refresh tokens rotate, the new token is written back to the same file
  Claude Code reads, so the CLI picks it up on next use. It only refreshes when
  the token is within 60s of expiry (or on a 401).

## Remove

```bash
rm ~/.local/bin/clusage-waybar
rm -rf ~/.cache/clusage
# then delete the custom/clusage module + modules-right entry from
# ~/.config/waybar/config.jsonc and the #custom-clusage rules from style.css
omarchy restart waybar
```
