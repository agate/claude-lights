# Demo media for the website

Re-records the screenshots and the demo video on `site/` with **synthetic sessions only**. Nothing from
the author's real Claude, tmux or herdr sessions can appear: the demo app instance reads a fake registry
(`CLAUDE_LIGHTS_SESSIONS_DIR`) and a separate tmux server (`TMUX_TMPDIR`).

## Run

```sh
scripts/bundle.sh                         # the app that gets recorded: build/ClaudeLights.app
python3 scripts/demo/scenario.py setup    # fake sessions, Terminal windows, clean Chrome, demo app
python3 scripts/demo/scenario.py record   # ~45 s; moves and clicks the mouse — hands off
python3 scripts/demo/scenario.py shot     # site stills: bar.png, menu.png, notification.png
python3 scripts/demo/scenario.py teardown # restores everything and relaunches the real app
python3 scripts/demo/post.py              # captions, highlights, ping, blur -> site/media/
cp build/demo/{bar,menu,notification}.png site/media/
```

`record` and `shot` hide every other app while they run and unhide them afterwards.

## What each piece does

- `fake_claude.py` draws a Claude Code-like screen for one made-up session (`docs-site`, `api-server`,
  `data-pipeline`, `blog`, `mobile-app`, `notes`) and redraws when its state file changes.
- `scenario.py` writes the fake registry records, starts the tmux server (with `-f /dev/null`, so the
  user's theme and host name stay out), opens Terminal.app windows (not iTerm2, which holds the user's
  own windows), a fresh-profile Chrome, and the demo app. It drives the timeline and logs every event to
  `build/demo/events.json`.
- `post.py` downscales the Retina recording, then burns in one caption track per language, a 3x inset of
  the bar with a ring on the light that changed, blurs the menu bar except the Claude Lights dot, and mixes
  `/System/Library/Sounds/Ping.aiff` at each banner (screen recording has no audio).
- `mouse.swift` / `windows.swift` are tiny helpers for synthetic input and window/status-item frames.

## Gotchas (each one cost a retake)

- Launch the demo app with `open <path> --env ...`, never `open -n`: a second instance is refused
  notification permission and only plays the sound.
- A session notifies with its session id as the notification id, so its second notification only
  updates the first one silently: no banner, no sound. `post.py` adds pings only for first ones.
- The app shows a session with no transcript as hollow gray, so `setup` writes a one-line transcript
  under `~/.claude/projects/-Users-demo-projects-*`; `teardown` deletes them.
- `pgrep -f` patterns must be anchored (`^python3 ...`): the tmux server's command line contains the
  fake script path too.
- Terminal ignores SIGTERM while asking about running processes, and reopens old windows after a
  force-quit: use `pkill -9` and `-ApplePersistenceIgnoreState YES`. Its titles show the home folder and
  command, so the Basic profile is switched to custom titles; the original prefs are restored.
- `defaults write -array` stores strings; the bar position must be written as real numbers (plist import).
- Notification banners are drawn without a listable window: `shot` captures the top-right corner.
- Docker's ffmpeg VM has 2 GB: compose at 1x, and use single-frame overlay inputs with
  `eof_action=repeat` rather than `-loop 1`.
- This machine's `log` and `ffmpeg` are shell wrappers; use `/usr/bin/log` and the Docker image.
