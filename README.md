# Claude Lights

A macOS menu bar app that shows every local Claude Code session as a traffic
light — red means a session is waiting for you, yellow means it is working,
green means it is idle/done (and dims once you've looked at it). Includes an
always-on-top floating light bar, one-click jump to the session's tmux
window, and a notification with sound when a session starts waiting.

![Floating light bar — one dot per session: waiting, working, idle (unseen), idle (seen)](assets/screenshot-bar.png)

The bar updates live as sessions change state:

![A session cycling through working, waiting-for-you, and idle](assets/demo.gif)

## Requirements

- macOS 13+
- Claude Code ≥ 2.1.139 (reads `~/.claude/sessions/*.json`)
- tmux (optional — needed for click-to-jump)

## Build & run

```bash
scripts/bundle.sh
open build/ClaudeLights.app
```

Grant the notification permission on first launch.

## Usage

- **Menu bar dot** shows the aggregate state (red if any session needs you).
- **Click the dot** for a per-session list; click a row to jump to its tmux window.
- **Floating bar**: one dot per session, hover for details, click to jump,
  drag to reposition. Toggle it from the menu.
- **Launch at Login** is in the menu (requires the .app bundle).
