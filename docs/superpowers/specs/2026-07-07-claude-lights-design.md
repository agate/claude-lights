# Claude Lights — Design Spec

Date: 2026-07-07
Status: Approved pending user review

## Overview

Claude Lights is a native macOS menu bar app that shows the live status of all
local Claude Code sessions as traffic lights, so the user does not have to
keep watching terminals. It has two UI surfaces — an always-on-top floating
light bar and a menu bar (tray) dropdown — plus notifications with sound when
a session starts waiting for the user.

Inspired by [tmux-claude-session-manager](https://github.com/craftzdog/tmux-claude-session-manager),
which proved that Claude Code publishes session state with no hooks required.

## Goals

- See at a glance which sessions need attention (waiting for input/permission).
- Jump to the session's tmux window with one click.
- Get notified (banner + sound + descriptive text) the moment a session turns red.
- Zero setup inside Claude Code: no hooks, no wrappers.

## Non-goals (v1)

- Showing standalone `kind: "bg"` jobs (no terminal to jump to). But note:
  a session moved to the background keeps a stale interactive registry
  record alongside a live bg record under the same sessionId — those twins
  are merged (freshest record wins the status, the interactive one's tty
  provides the jump target), otherwise the light freezes on the stale twin.
- Live screen previews of sessions.
- Controlling sessions (sending input, killing) from the app.
- Linux/Windows support.

## Data sources (verified on this machine)

1. **`claude agents --json`** (Claude Code ≥ 2.1.139; 2.1.207 installed).
   Returns one object per session: `pid`, `cwd`, `kind`
   (`interactive`/`background`), `startedAt`, `sessionId`, `name`, `status`
   (`busy`/`idle`), and sometimes `state` (`done`). Backed by the per-process
   registry files at `~/.claude/sessions/<pid>.json`. The app reads those registry files directly (with a
   `kill(pid, 0)` liveness check to skip stale files) — spawning the `claude`
   CLI every 2 s is too heavy. The CLI remains the reference for the schema.
2. **`ps -o tty= -p <pid>`** — maps a session's PID to its controlling tty.
3. **`tmux list-panes -a -F '#{pane_tty} #{session_name} #{window_index}'`** —
   maps ttys to tmux windows. Joining (2) and (3) locates each session's
   tmux window, exactly like the reference project.
4. **Transcript tail**: `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`.
   Used to extract a one-line description of what a waiting session is
   waiting for (e.g. pending permission request or last assistant message),
   and optionally a topic line from the first user message.

**Session titles (corrected 2026-07-07):** the AI-generated session title
shown by `/status` and `/resume` IS persisted — as
`{"type":"ai-title","aiTitle":"..."}` lines appended to the session's own
transcript jsonl (newest occurrence wins). Earlier "not persisted" finding
was wrong: transcripts contain binary bytes, so ripgrep silently skipped
them without `-a`. The app uses this title as the primary display label,
falling back to the **basename of `cwd`** when absent (title generation is
lazy). The `name` field remains a derived short code (e.g. `dev-0b`),
shown only as secondary text. Title lookup scans a large transcript tail on
first sight of a session, then only a small tail per poll, cached in memory.

**Verified live (2026-07-07, 2.1.207):** a session waiting for permission
approval reports `"status": "waiting"` plus a bonus field
`"waitingFor": "permission prompt"` — a human-readable wait reason the app
uses as the primary notification description (transcript tail as enrichment).
Note the registry files use `"kind": "bg"` for background agents (the CLI
prints `"background"`); the app filters on `"interactive"`, unaffected.
Unknown values must map to a conservative neutral color, never crash.

## State model

Each state is encoded on two independent channels — a colorblind-safe hue
(Okabe-Ito palette) and a glyph/shape — so no state is distinguishable by
color alone (a colleague is colorblind).

| Light | Color | Glyph/shape | Meaning | Source values |
|-------|-------|-------------|---------|---------------|
| Red | vermillion `#D55E00` | `!` | Waiting for the user (input / permission) | `waiting` |
| Yellow | amber `#E69F00` | gear (spins in the bar) | Working | `busy`, `shell`, `working`, `running` |
| Green | bluish-green `#009E73` | `✓` | Idle / done, not yet looked at | `idle`, `state: done` |
| Dim green | gray, filled | (none) | Idle / done, already seen | green + seen |
| Gray | gray, hollow ring | (none) | Brand-new (no transcript) / unknown | anything else |

Sort order everywhere: **stable, by session launch time** (oldest first,
ties by id). A session keeps its position for its whole life; only its
color/glyph changes as it works/waits/finishes. (Earlier builds sorted by
state — red first — but that made dots jump around on every status change,
defeating muscle memory. Urgency is still obvious from color + glyph.)

**Seen tracking (added 2026-07-07):** a green session counts as "seen" when
the user jumped to it from the app, or when it is genuinely on screen — its
tmux window is the active window of the tmux session attached to the
*frontmost terminal tab*. That last part matters: a terminal being frontmost
is not enough, because a background tab's tmux client stays attached and its
window stays active. The focused tab's tty is read via AppleScript (iTerm2 /
Apple Terminal); terminals without that interface (incl. VS Code) can't be
resolved, so their sessions are never auto-seen (conservative: a finished
session then shows bright green + notifies rather than being silently
dimmed). The same focused-tab test gates notification silencing. Turning
busy/waiting again resets to unseen. Seen state is in-memory only (app
restart shows everything bright green — conservative).
Idle sessions display an explicit idle duration ("Idle for 12m") in the menu
and hover tooltip, derived from `statusUpdatedAt` (which only changes on
status transitions).

## Architecture

Swift + AppKit/SwiftUI menu bar app (`LSUIElement`, no Dock icon). Four modules:

### 1. Poller
- FSEvents on the registry directory triggers near-instant status polls (0.5 s debounce); a 10 s fallback timer covers tmux visibility sampling, screen following, pid liveness, and age refresh. Each poll: read registry files and `tmux list-panes -a`, join with
  `ps` tty lookups, produce `[Session]` (value-type model).
- Filters to `kind == "interactive"`.
- Publishes snapshots to the UI via an observable store; diffs snapshots to
  detect state transitions (for notifications).
- All subprocess work off the main thread; a poll failure keeps the last
  snapshot and sets an error flag.

### 2. Floating light bar (NSPanel)
- Borderless, rounded, always-on-top, **non-activating** (clicking it never
  steals focus), visible on all Spaces and over full-screen apps
  (`.canJoinAllSpaces`, `.fullScreenAuxiliary`).
- One colored dot per session, sorted red-first. Hover shows a tooltip:
  project name + state. Click jumps to the session.
- Draggable; position persisted in `UserDefaults`. Auto-hides when there are
  no sessions. Can be toggled from the tray menu.

### 3. Tray menu (NSStatusItem)
- Icon reflects aggregate state: red if any session is red, else yellow if
  any busy, else green; gray on error/empty.
- Menu rows: `● <project> — <derived name> — <state> · <age>`; clicking a row
  jumps to that session.
- Footer items: Show/Hide light bar, Launch at login, Quit.

### 4. Jumper + Notifier
- **Jump** (updated 2026-07-07 for multi-tab iTerm2 setups):
  1. `tmux select-window` + `select-pane` make the claude pane current
     inside its tmux session;
  2. if no client is attached to that tmux session, one is retargeted via
     `switch-client -c <client_tty>`;
  3. the client's hosting app is identified by walking its process
     ancestry, then focused per terminal:
     - iTerm2 / Apple Terminal: AppleScript tty matching selects the exact
       window/tab (`NSAppleEventsUsageDescription` declared; user grants
       automation once per app);
     - VS Code (tmux inside the integrated terminal): all integrated
       terminals live in one shared pty-host process, so a tty cannot
       select a window — instead `code <session cwd>` focuses the window
       whose workspace has that folder open (window-level only; selecting
       the terminal tab inside would need a companion extension).
     Fallback when nothing matches or automation is denied: activate the
     hosting terminal app. Sessions with no tmux pane (bare
     tty) still show status; a click activates the terminal only.
- **Notify**: on transition *into* red only (no repeats while red persists):
  `UserNotifications` banner + sound. Title: project name. Body: derived
  name + what it is waiting for, extracted from the transcript tail and
  truncated to one line. Clicking the notification jumps to the session.

## Edge cases

- `claude` CLI missing or too old → gray tray icon with an explanatory
  disabled menu item.
- A session running Claude Code < 2.1.207 (read from the registry's
  `version` field) → a menu advisory, since that version can't report the
  `waiting` status the red light depends on. Different sessions may run
  different versions simultaneously, so this is per-session, not a global
  block.
- No sessions → light bar hidden, tray gray.
- tmux server not running → statuses still shown; jump disabled per session.
- Malformed/unknown JSON fields → gray state, never crash.

## Testing

- Unit tests with fixture CLI outputs: JSON parsing, state→color mapping,
  tty→pane joining, transition detection (notification trigger), transcript
  tail extraction.
- Manual acceptance: floating bar behavior (focus, Spaces, drag), jump,
  notification click-through.

## Project layout

- Repo: `/Users/dev/claude-lights`
- Swift Package Manager executable target + a small app bundle build script
  (no Xcode project required); details left to the implementation plan.
