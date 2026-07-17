# Claude Lights — working notes

macOS menu-bar app showing local Claude Code sessions as traffic lights, with
a floating light bar and one-click jump to a session's terminal tab.

**Authoritative design + decisions:** `docs/superpowers/specs/2026-07-07-claude-lights-design.md`.
Read it before changing behavior. Per-fix rationale lives in `git log`.

## Layout
- `Sources/ClaudeLightsCore` — pure, fully unit-tested logic (parsing, state
  mapping, tmux joining, sorting, transitions). No AppKit.
- `Sources/ClaudeLights` — AppKit/SwiftUI shell (poller, tray, floating bar,
  jumper, notifier). Not unit-tested; verify by running.

## Build / test / release
- `swift test` — runs the Core suite (keep it green).
- `scripts/bundle.sh` — builds `build/ClaudeLights.app` (universal, ad-hoc
  signed). Relaunch after building: `open build/ClaudeLights.app`.
- Release: bump `CFBundleShortVersionString`/`CFBundleVersion` in
  `scripts/bundle.sh`, `ditto -c -k --keepParent build/ClaudeLights.app X.zip`,
  `gh release create vX.Y.Z X.zip`.

## Hard-won facts (don't re-derive)
- **Data source is the registry, not the CLI.** Read `~/.claude/sessions/<pid>.json`
  directly (with `kill(pid,0)` liveness); `claude agents --json` is only the
  schema reference. Registry uses `kind:"bg"` (CLI prints `"background"`).
- **Status values:** `busy`/`shell`/`working`/`running` → working; `waiting`
  (+ `waitingFor` reason) → needs-you (red); `idle`/`state:done` → done.
  Unknown → gray, never crash. `waiting` requires Claude Code ≥ 2.1.207.
- **A backgrounded session leaves a stale interactive record + a live bg
  record under one sessionId** — merge by sessionId, freshest wins status.
- **Session title** (`/status`/`/resume`) is persisted as `ai-title` lines in
  the transcript jsonl; transcripts contain binary bytes so `rg` needs `-a`.
- **tmux from a Finder-launched GUI app:** its `$TMPDIR` differs from the
  terminal's, so locate the server socket explicitly (`Tmux` helper scans
  `TMUX_TMPDIR`/`TMPDIR`/`/tmp`, passes `-S`). And **this tmux sanitizes tabs
  in `-F` output to `_`** — field separator is the printable `|CL|`, not `\t`.
- **Jump:** tmux → `select-window`/`select-pane` + focus the client tab by
  tty (AppleScript). Non-tmux → focus by the session's own tty. VS Code →
  `code <cwd>` (no per-tab tty). Menu rebuilds on open (NSMenuDelegate) so
  toggle checkmarks are live.
- **Seen/on-screen** = the session's tmux window is active in the client on
  the *frontmost tab* (frontmost-tty via AppleScript), not just any terminal
  frontmost. Dot order is **stable by launch time**, never by state.

## Open issue
- App is **ad-hoc signed** (no Team ID). macOS Automation (AppleScript)
  permission is fragile across reboots/rebuilds — jump can silently stop
  focusing tabs until re-granted. Real fix: Developer ID signing + notarize
  (Apple Developer Program). Not done.
