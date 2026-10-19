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
- App icon: edit `assets/icon.svg`, then `scripts/make_icon.sh` regenerates
  `assets/icon-1024.png` and `assets/AppIcon.icns` (bundle.sh copies the .icns).
  `site/favicon.svg` is the same drawing cropped to the plate.
  Notification banners keep the old icon until every other copy of the bundle id
  (e.g. an old `/Applications/ClaudeLights.app`) is gone and the per-user caches
  are cleared: `rm -rf "$(getconf DARWIN_USER_CACHE_DIR)"com.apple.{iconservices,notificationcenterui}`
  then `killall iconservicesagent usernoted NotificationCenter`.
- Release: bump `CFBundleShortVersionString`/`CFBundleVersion` in
  `scripts/bundle.sh`, `ditto -c -k --keepParent build/ClaudeLights.app X.zip`,
  `gh release create vX.Y.Z X.zip`.

## Hard-won facts (don't re-derive)
- **Data source is the registry, not the CLI.** Read `~/.claude/sessions/<pid>.json`
  directly (with `kill(pid,0)` liveness); `claude agents --json` is only the
  schema reference. Registry uses `kind:"bg"` (CLI prints `"background"`).
- **Status values:** `busy`/`working`/`running` → working; `shell` → greenBg
  (main thread answered, background task still running — green disc, static
  gear; verified on 2.1.212 that foreground commands report `busy`, though
  2.1.209 reported `shell` for those too); `waiting` (+ `waitingFor` reason)
  → needs-you (red); `idle`/`state:done` → done. Unknown → gray, never
  crash. `waiting` requires Claude Code ≥ 2.1.207. greenBg notifies once on
  busy→shell (the answer), never again on shell→idle.
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
- **herdr:** claude inside herdr has a herdr-owned pty, so its tty matches
  no terminal tab. Join by sessionId from `herdr agent list`
  (`agent_session.value`, needs the herdr claude integration); jump =
  `herdr agent focus <pane>` + focus the tab running the `herdr` client (ps).
  Save skips herdr sessions — herdr resumes them itself.
- **Seen/on-screen** = the session's tmux window is active in the client on
  the *frontmost tab* (frontmost-tty via AppleScript), not just any terminal
  frontmost. Dot order is **stable by launch time**, never by state.
- **Auto-update:** `GitHubUpdater` polls `releases/latest` (launch + 24 h),
  UI talks only to the `UpdaterEngine` protocol (Sparkle-swappable, see
  docs/superpowers/specs/2026-07-17-auto-update-design.md). Installer picks
  zip/app by extension, validates bundle id, swaps with rollback. Keep tags
  `vX.Y.Z` == `CFBundleShortVersionString`, zip via `ditto --keepParent`.
  E2E test: lower the bundle's version, relaunch with
  `CLAUDE_LIGHTS_DEMO_AUTOINSTALL=1` — it self-updates from the live release.
- **Save/Restore sessions:** snapshots live in iCloud Drive
  (`ClaudeLights/sessions/<ComputerName>/<name>.json`, old tmux-claude v2
  format), never locally. Non-tmux Claude sessions are saved together as
  `claude-loose-sessions` and restored into a tmux session of that name.
  Save only rewrites files of sessions running now. Single-pane windows are
  targeted by window (not `.0`) so `pane-base-index` doesn't matter.
- **Close session** (⌥ on a tray row, or right-click a bar dot → Close;
  both confirm): stops every live pid of the session (bg record too) and
  the process groups of its Bash commands — each tool call leads its own
  group, so neither SIGTERM to claude nor `kill-pane` reaches them;
  collect them *before* claude exits (they re-parent to launchd). Then
  only Claude's own pane: `kill-pane -t %id` / `herdr pane close` / the
  terminal tab with claude's tty (Terminal.app's AppleScript
  can only close windows: closed only when it is the window's sole tab);
  VS Code = process only. Bar menu summary
  = newest `away_summary` recap, else `last-prompt` (2 MB tail).
- **Auto-save** (on by default, toggle in Restore ▸ Auto Saved): every 15 s
  builds the same snapshots into `.../<ComputerName>/auto-saved/`, written
  only when the structure changed *and* held for two ticks (so a shutdown
  tearing panes down never overwrites a good file); claude `status` is
  ignored. Silent — errors only go to `~/Library/Logs/ClaudeLights/autosave.log`
  (1 MB, one `.1` rotation), each distinct error logged once.

## Open issue
- App is **ad-hoc signed** (no Team ID). macOS Automation (AppleScript)
  permission is fragile across reboots/rebuilds — jump can silently stop
  focusing tabs until re-granted. Real fix: Developer ID signing + notarize
  (Apple Developer Program). Not done.
- iCloud Drive access (Save/Restore snapshots) is another TCC (macOS privacy)
  permission that ad-hoc rebuilds can reset; if denied, Save/Restore show the
  raw permission error.

## Website (`site/`)
- `site/` is the product page, served at https://honghao.me/claude-lights/ by
  `.github/workflows/site.yml` (GitHub Pages, project page under the
  agate.github.io custom domain). Plain static HTML + `style.css`, no build.
- It follows the honghao.me style rules — read `CLAUDE.md` in
  agate/agate.github.io (`~/workspaces/honghao.me/CLAUDE.md`) before editing:
  isometric line art, Instrument Serif / Inter / LXGW WenKai (Chinese, from
  jsDelivr) / JetBrains Mono, hairline rules, and every visible string in both
  `lang="en"` and `lang="zh"` (EN / 中 toggle; `localStorage` key `lang` is
  shared with honghao.me).
- Illustrations: `python3 scripts/gen_site_art.py` writes `site/art/*.svg`;
  never edit those by hand. State colors match the app (Okabe-Ito vermillion
  `#d55e00`, amber `#e69f00`, bluish-green `#009e73`).
- Media in `site/media/` (demo videos per language, bar/menu/notification
  stills, the jump clip) is produced by `scripts/demo/` with synthetic
  sessions only — see `scripts/demo/README.md`. Never record or screenshot
  the author's real sessions, tmux, herdr, Restore menu or Notification Center.
- Author name is **`Hong, Hao`** (surname first, with the comma) in both
  languages. The footer must link back to the main domain with a relative
  `href="/"` — never a hard-coded `https://honghao.me/` — so a domain change
  in agate.github.io's `site.config.mjs` needs no edit here.
- The "Why I built it" section is the author's own reasoning — keep its
  substance; don't rewrite it into marketing copy.
