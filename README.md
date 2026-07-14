# Claude Lights

A macOS menu bar app that shows every local Claude Code session as a status
dot. Each state is encoded twice — a colorblind-safe color **and** a glyph —
so it reads clearly regardless of color vision:

| Dot | State |
|-----|-------|
| **!** vermillion | Waiting for you (input / permission approval) |
| ⚙ amber (spinning) | Running (working) |
| **✓** bluish-green | Done — finished, not yet looked at |
| filled gray | Idle — already seen |
| hollow gray | Just started, nothing yet |

Includes an always-on-top floating light bar, one-click jump to the
session's tmux window (iTerm2, Apple Terminal, or VS Code), and a
notification with sound when a session needs you or finishes.

![Floating light bar — one dot per session: waiting (!), running (spinning gear), done (✓), idle seen, just started](assets/screenshot-bar.png)

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
asks once for permission to control your terminal (iTerm2, Apple Terminal,
or VS Code).

## Usage

- **Menu bar dot** shows the aggregate state — red if any session needs you,
  else the spinning gear if any is running, else green/gray. Click it for a
  per-session list (project, state, idle duration); click a row to jump.
- **Floating bar**: one dot per session, sorted so whatever needs you comes
  first. Hover for details, click to jump, drag to reposition.
  - Drag it near the **top-right corner** to magnetically pin it there; it
    then stays flush with that corner as sessions come and go. Drag it away
    to unpin.
  - It **follows the screen you're working on** and moves to a remaining
    screen if you unplug a monitor.
- **Jump** switches tmux to the session's window/pane and focuses the exact
  iTerm2 / Apple Terminal tab, or the VS Code window for its folder. If every
  terminal window is closed, it offers to open a new one attached to the
  session.
- **Idle sessions** dim from bright to muted green once you've looked at
  them, so unread results stand out.
- **Notifications** fire (banner + sound) when a session turns red or
  finishes working — silenced automatically when you're already looking at
  that session's window. Toggle sound with **Notification Sounds** in the menu.
- **Show Light Bar**, **Launch at Login** (requires the .app bundle), and
  **Quit** are in the menu.
