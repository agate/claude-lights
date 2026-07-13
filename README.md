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

## Install

### Option 1 — Build from source (recommended)

```bash
git clone https://github.com/agate/claude-lights.git
cd claude-lights
scripts/bundle.sh
open build/ClaudeLights.app
```

Building locally avoids macOS quarantine entirely and lets you audit what
you run. Requires the Xcode command line tools (`xcode-select --install`).

### Option 2 — Download a release

Grab `ClaudeLights.zip` from the [latest release](https://github.com/agate/claude-lights/releases),
unzip, and move `ClaudeLights.app` wherever you like (e.g. `/Applications`).

The app is not notarized (no Apple Developer certificate), so on first
launch macOS will refuse to open it. Either:

- open **System Settings → Privacy & Security** and click **Open Anyway**
  after the first failed attempt, or
- clear the quarantine flag yourself:

  ```bash
  xattr -d com.apple.quarantine /path/to/ClaudeLights.app
  ```

The binary is universal (Apple Silicon + Intel).

### First launch

Grant the notification permission when asked; the first click-to-jump also
asks once for permission to control iTerm2/Terminal.

## Usage

- **Menu bar dot** shows the aggregate state (red if any session needs you).
- **Click the dot** for a per-session list; click a row to jump to its tmux window.
- **Floating bar**: one dot per session, hover for details, click to jump,
  drag to reposition. Toggle it from the menu.
- **Launch at Login** is in the menu (requires the .app bundle).
