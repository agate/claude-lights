# Usage meter — design

## Intent

Show how much of the account's Claude limits are left without opening
`/usage`: the 5-hour session limit at a glance in the tray, and the weekly
per-model limit (Fable) plus the extra-usage credit in the menu.

## Data source (decided)

Claude Code caches `/usage` in `~/.claude.json` (`cachedUsageUtilization`),
but only rewrites it when `/usage` opens, an SDK client sends `get_usage`, or
once a day at startup — it is routinely many hours stale. Rate-limit response
headers carry only the 5h/7d windows, never the per-model weekly limit or
credit, and only reach the CLI anyway.

So the app asks Claude Code itself, every **30 minutes**, at launch, and when
the menu's refresh button is clicked:

```sh
claude -p --input-format stream-json --output-format stream-json --verbose \
  --settings '{"disableAllHooks":true}' --strict-mcp-config --no-session-persistence
# stdin: {"type":"control_request","request_id":"usage","request":{"subtype":"get_usage","skip_behaviors":true}}
```

- No model call, $0, ~1 s. The CLI exits when stdin closes.
- The OAuth token stays inside Claude Code; the app never reads it.
- The answer is read from stdout (`control_response.response.rate_limits`),
  not from the cache file — the CLI throttles cache writes.
- The probe registers itself in `~/.claude/sessions/` like any session. It runs
  with its own cwd (`~/Library/Caches/ClaudeLights/usage-probe`) and the
  poller drops registry records with that cwd, so no phantom dot appears.
- Hooks and MCP servers are off for the probe: the user's SessionStart hooks
  would otherwise run on every fetch.
- Undocumented interface: every field is best-effort; anything missing hides
  its row rather than failing.
- Signed out (or an API key) is still a `success` answer, with
  `rate_limits_available:false, rate_limits:null`. That answer **clears** the
  last report (no meter, no section). Other failures — timeout, crash, an
  `error` subtype — keep the last report, which fades as it goes stale.

## Tray (decided)

- The existing state disc is unchanged. A **vertical bar** sits right of it:
  outline always drawn, filled bottom-up by the 5h session percent used.
- No number. The bar is drawn in the menu-bar label color (follows light /
  dark menu bar; template when Monochrome Icons is on), never a state color.
- No data → no bar (tray looks exactly as before). Data older than 45 min
  (one refresh missed) → bar drawn faded.

## Menu (decided)

A "Usage" section at the top of the menu (above the session list):

```
Usage                       Updated 2 min ago  ↻
Session (5h)       91% left · resets 3:40 AM
████░░░░░░░░
Fable (weekly)     94% left · resets Thu 6:00 PM
Credit             $191.90 left of $200
```

The ↻ button fetches now; the header reads "Updating…" until the answer
(or a failure) comes back, and the section updates in place while open.

Each row has a thin neutral meter of the used fraction. Weekly rows come from
`limits` entries with `group == "weekly"`, titled by `scope.model.display_name`
(else "All models"). Credit shows only when `extra_usage.is_enabled` and a
monthly limit exists. A row whose data is missing is omitted; with no rows at
all the section is omitted.

## Builder's calls

- Reset time: time only if today, else weekday + time, in the user's locale.
- Menu text in English, like the rest of the menu.
- Opening the menu does not trigger a fetch.
- Failures go to `~/Library/Logs/ClaudeLights/usage.log`, each distinct error
  once (same pattern as auto-save).
- Parsing and row formatting live in Core with unit tests; the probe runner,
  tray drawing and menu view live in the app.

## Non-goals

Notifications near the limit; usage on the floating bar; per-conversation
token counts.
