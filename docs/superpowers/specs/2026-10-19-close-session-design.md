# Close Session Design

Date: 2026-10-19
Status: approved

## Goal

Close a running Claude Code session from Claude Lights without going to its
terminal: end the `claude` process **and** remove the tmux pane (or herdr
pane, or terminal tab) it lived in. Two entry points, both behind a
confirmation alert:

1. The tray menu: hold ⌥ and a session row turns into `Close “<name>”…`
   (same mechanism as the ⌥ Delete alternate on Restore rows).
2. The floating bar: right-click a dot to get a context menu with details
   about that session and a `Close “<name>”…` item at the bottom.

Why: closing a session today means jumping to it, quitting Claude, then
closing the pane by hand. With many sessions this is the slowest part of
cleaning up.

## Decisions (from brainstorming)

- **Close = two steps, in order:** end the Claude process, then remove its
  container. Both always happen in one action; there is no "only kill" or
  "only close pane" variant.
- **tmux: close only Claude's own pane.** Other panes in the same window
  stay untouched. If Claude's pane was the window's only pane, tmux closes
  the window itself (normal tmux behavior; nothing extra to do).
- **Not in tmux:** end the Claude process. Then close its container *if we
  can*, otherwise do nothing extra:
  - herdr → `herdr pane close <pane_id>` (claude's own herdr pane).
  - iTerm2 / Apple Terminal tab → close the tab/session whose tty equals
    the session's own `tty` (the same tty matching `Jumper` uses to focus).
    Apple Terminal's AppleScript cannot close a single tab (only windows),
    so there the window is closed only when that tab is its sole tab.
  - VS Code, or no tab matches → process only.
- **Both entry points confirm** with an `NSAlert` before doing anything.
- **Bar context menu content**, top to bottom:
  1. Title (`displayName`), disabled.
  2. Separator.
  3. Project path (`cwd`, with `~` for the home dir).
  4. Status (`statusText`, plus `waitingFor` when present).
  5. Location (see "Location line").
  6. Claude Code version.
  7. Separator.
  8. Summary block (see "Summary").
  9. Separator.
  10. `Close “<name>”…`.
- **Summary = the newest recap, else the last prompt.** No live model call.
- **Left-click on a dot is unchanged** (still jumps).

## Behavior details

### Ending the Claude process

Targets: **every live registry record in the session's group**, not just
`session.pid`. A backgrounded session has an interactive record plus a
live `kind:"bg"` record under the same sessionId (merged by
`SessionBuilder`), and the bg process may be the one doing the work. If
only the interactive pid died, the bg record would keep the dot alive and
the close would look like it failed. *(Builder-check finding; my call.)*
So `Session` gains a `pids: [Int]` field (all record pids of the group),
filled by `SessionBuilder`.

For each target pid:

1. Send `SIGTERM`.
2. Poll `kill(pid, 0)` for up to 3 s (all pids in parallel, one shared
   deadline).
3. If still alive, `SIGKILL`.

PID reuse guard: right before each signal, re-check that
`~/.claude/sessions/<pid>.json` still exists and its `sessionId` is this
session's id. If the record is gone, the process is gone; skip it.

**Commands Claude started are stopped too** (user decision). Each Bash
tool call runs as a direct child of Claude in its *own* process group, so
neither signalling Claude nor `kill-pane` / closing a tab reliably stops
them (e.g. a `npm run dev` would be orphaned, always so for VS Code).
Before signalling a Claude pid, collect its children's process groups
from `ProcessTable` (the same `/shell-snapshots/snapshot-` children
`claudeCommandCount` counts) and send each group `SIGTERM` (`kill(-pgid,
…)`), then `SIGKILL` at the same 3 s deadline if any member is still
alive. Collect the list *before* signalling Claude: once Claude exits its
children are re-parented to launchd and can no longer be found by parent.
MCP servers and other helpers are not touched here; they normally exit
with Claude.

Bg-only groups (no interactive record) never appear in `Session` lists, so
they cannot be closed from the UI.

### Removing the container

Runs after the process is gone (or after `SIGKILL` was sent).

| Session has | Action |
|---|---|
| `tmuxPane` (e.g. `%12`) and tmux available | `tmux kill-pane -t <tmuxPane>` |
| `herdrPane` and herdr available | `herdr pane close <herdrPane>` |
| `tty`, no tmux/herdr | AppleScript: close the iTerm2 session / Terminal tab whose tty matches; iTerm2 first, then Terminal (same order as `Jumper.focusTab`) |
| none of the above | nothing |

Notes:
- A pane id (`%N`) is unique for the life of the tmux server, so it is the
  safe target. If the pane is already gone (e.g. restored panes run
  `claude --resume` as the pane command and die with it), `kill-pane`
  fails; ignore that.
- Do not close a tmux session/window by name — only the pane.
- For a terminal tab, only close the tab whose tty matched; never the
  frontmost one as a fallback. After Claude exits the tab holds only a
  shell, so Terminal/iTerm2 should close without their "processes are
  running" prompt; if they prompt anyway, let them.
- VS Code: the session's tty is a VS Code pty — no AppleScript host matches
  it, so the table naturally falls to "nothing".

### Confirmation alert

- `NSApp.activate(ignoringOtherApps: true)` first (LSUIElement app — same
  as `confirmDelete`), then `runModal()`.
- Title: `Close “<displayName>”?`
- Body: what will happen, chosen from the same decision as the table above,
  e.g. "Claude will be stopped and its tmux pane (main:2) closed. Other
  panes in that window stay open." / "…and its Terminal tab closed." /
  "Claude will be stopped. Its window is left open."
- Extra warning line when `light == .yellow` ("It is working right now.")
  and/or `backgroundTasks > 0` ("The N commands it started will be
  stopped too.").
- Buttons: `Close` (default) and `Cancel`.

### After closing

- The work runs off the main thread (signals + 3 s wait must not freeze the
  menu or bar).
- No success notification. On failure (e.g. `kill` returned `EPERM`), post
  `notifier.notifyInfo(title: "Close Session", body: <reason>)`.
- The session's registry file disappears when Claude exits, so the
  existing `RegistryWatcher` → poll path removes the dot/row. No special
  refresh needed.

### Location line

Pure function in Core so it is testable:

- tmux: `tmux: <session>:<window>.<paneIndex>` when the pane index is
  known, else `tmux: <session>:<window>`.
- herdr: `herdr: <herdrPane>`.
- otherwise: `Terminal tab` when a `tty` exists, else `No terminal`.
  (VS Code-hosted bare sessions will read `Terminal tab`; acceptable.)

### Summary

Read on context-menu open (not every poll), from the transcript at
`TranscriptReader.transcriptURL(cwd:sessionId:)`:

1. **Recap:** the newest line with `"type":"system"` and
   `"subtype":"away_summary"`. Use its `content` and `timestamp`.
   Strip the trailing ` (disable recaps in /config)` hint and any trailing
   date-stamp line Claude Code appends (e.g. `[2026-10-15]` or
   `` `2026-10-17` ``). Header: `Recap · <age> ago` (age from
   `timestamp`, using `AgeFormatter`).
2. **Else last prompt:** the newest `"type":"last-prompt"` line's
   `lastPrompt`. Header: `Last prompt`. (These lines carry no timestamp.)
3. **Else** omit the summary block and its separator.

Reading: the recap can be far from the end of a long transcript, so read a
larger tail than the 64 KB default — e.g. 2 MB — once per menu open.
Transcripts contain binary bytes; decode lossily rather than failing (the
existing `String(data:encoding:.utf8)` returns nil on bad bytes — the new
reader must not give up on that).

Display: word-wrapped to about 50 characters per line, at most 6 lines,
the last truncated with `…`. Rendered as disabled menu item(s) in the
secondary label color.

### Tray menu ⌥ alternate

- Each session row gets a sibling `NSMenuItem` with `isAlternate = true`,
  `keyEquivalentModifierMask = .option`, title `Close “<displayName>”…`,
  calling a new `onCloseSession` callback.
- Rows are now two-line attributed titles (uncommitted work on `main`). The
  alternate should keep the same two-line height so the menu doesn't jump
  when ⌥ is pressed: line 1 `Close “<name>”…`, line 2 the same plain-words
  description as the alert body's first sentence.
- The alternate keeps the session's status image.

### Bar right-click

The bar is a non-activating `NSPanel` with a SwiftUI `BarView` hosted in
`FirstMouseHostingView`. Builder's choice how to catch the right-click
(SwiftUI `.contextMenu` vs. overriding `rightMouseDown` and hit-testing the
dot); it must work without the panel becoming key, and must not break
left-click jump or drag-to-move. Show a native `NSMenu`.
Clicking the path line copies `cwd` to the pasteboard; all other info
lines are disabled.

## Base

Built directly on `main` together with the uncommitted menu-row work
(two-line `MenuRow`, `backgroundTasks`, `AgeFormatter.short`,
`MenuRowTests.swift`), which this design depends on. The user chose this
over a worktree. The menu-row work is committed first, as its own commit,
then this feature on top.

## Code layout

- `ClaudeLightsCore` (unit-tested):
  - `CloseTarget` — enum `tmuxPane(id) | herdrPane(id) | terminalTab(tty) |
    processOnly`, computed from a `Session`. Plus its plain-words
    description used by the alert and the ⌥ row.
  - Location line formatter. Needs the tmux pane index: add
    `#{pane_index}` to the tmux list format and a `tmuxPaneIndex` field
    on `Session`.
  - `TranscriptReader.sessionSummary(fromJSONLines:)` → `{kind: recap |
    lastPrompt, text, date?}` incl. the hint/date-stamp stripping.
  - Wrap/truncate helper for the summary.
- `ClaudeLights` (AppKit, verify by running):
  - `SessionCloser` (new, beside `Jumper`): signals + wait + container
    removal. AppleScript tab-close lives here, mirroring `Jumper`'s
    focus scripts.
  - `StatusItemController`: ⌥ alternate + `onCloseSession`.
  - `FloatingBar`: right-click menu + `onCloseSession`.
  - `AppDelegate`: one `confirmClose(session:)` used by both entry points.

## Testing

- Core unit tests for `CloseTarget`, the command-process-group collection
  from a `ProcessTable` fixture, location line, summary extraction
  (recap present / only last-prompt / neither / recap with hint and date
  stamp / binary garbage lines), and wrapping.
- Manual: with synthetic sessions only (see `scripts/demo/README.md` for the
  rule) — a tmux window with two panes (Claude + shell; shell survives), a
  single-pane tmux window (window goes away), a bare Terminal tab, a bare
  iTerm2 tab, a herdr pane, a VS Code terminal (process only), Cancel in
  the alert (nothing happens), and a working session (warning shown).

## Non-goals

- No "close all" / multi-select.
- No undo / auto-resume after closing. The conversation itself is not
  lost: its transcript stays on disk, so `claude --resume <id>` (or
  `/resume` in a new Claude) brings it back. Save/Restore is *not* a
  safety net here: auto-save rewrites `auto-saved/` ~30 s after the pane
  disappears, so the closed pane drops out of that snapshot. Accepted.
  *(Builder-check finding; my call.)*
- No live AI summary.
- No right-click menu on tray menu rows (⌥ is the tray entry point).

## Left to the builder

- How to catch right-click on the bar (see above).
- Exact wrap width and wording of alert texts, within the intent above.
- Whether `SessionCloser` shares AppleScript helpers with `Jumper` or
  duplicates the small scripts.
