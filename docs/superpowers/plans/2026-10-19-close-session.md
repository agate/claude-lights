# Close Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close a running Claude session (its process, the commands it started, and its tmux/herdr pane or terminal tab) from the tray menu (⌥) or the floating bar's right-click menu, after a confirmation alert.

**Architecture:** Pure decisions (what to close, location line, summary extraction, command process groups) live in `ClaudeLightsCore` with unit tests. A new `SessionCloser` in the app target does the signals, waits and container removal off the main thread. `AppDelegate.confirmClose(_:)` is the single confirmation path for both entry points.

**Tech Stack:** Swift 5, AppKit + SwiftUI, XCTest, tmux / herdr CLIs, osascript.

**Spec:** `docs/superpowers/specs/2026-10-19-close-session-design.md`

## Global Constraints

- Signals: `SIGTERM`, wait up to **3 s** (one shared deadline), then `SIGKILL`.
- Close only Claude's own tmux pane (`kill-pane -t <%id>`); never a window or session by name.
- Terminal tab close only when its tty matches the session's own tty; iTerm2 first, then Apple Terminal.
- Recap: `"type":"system"`, `"subtype":"away_summary"`; strip ` (disable recaps in /config)` and a trailing date-stamp line. Fallback `"type":"last-prompt"` → `lastPrompt`.
- Summary tail read: 2 MB, lossy UTF-8 decode. Wrap ~50 chars/line, max 6 lines, `…` on the last.
- Alert title `Close “<displayName>”?`, buttons `Close` / `Cancel`.
- All code/comments/commits in English.

## Review Focus

1. Pid reuse: a registry file gone or holding another sessionId → that pid is never signalled (`SessionCloser` re-reads `<pid>.json` before each signal).
2. A command group whose leader already exited → `kill(-pgid)` returning `ESRCH` is not reported as a failure.
3. Transcript with invalid UTF-8 bytes in the tail → summary still found (test in Task 3).
4. Recap text with only the hint and date stamp → treated as empty, falls back to last prompt (test in Task 3).
5. Right-click on the bar must not trigger the left-click jump, and drag-to-move must still work (manual check in Task 6).

---

### Task 1: Session close target and location line

**Files:**
- Modify: `Sources/ClaudeLightsCore/TmuxMapper.swift` (panesFormat + parsePanes + `TmuxPane.paneIndex`)
- Modify: `Sources/ClaudeLightsCore/Session.swift` (`pids`, `tmuxPaneIndex`, builder fills them)
- Create: `Sources/ClaudeLightsCore/CloseTarget.swift`
- Test: `Tests/ClaudeLightsCoreTests/CloseTargetTests.swift`, `TmuxMapperTests.swift`, `SessionBuilderTests.swift`

**Interfaces:**
- Produces: `TmuxPane.paneIndex: String?` (6th `-F` field `#{pane_index}`; 5-field lines still parse with nil).
- Produces: `Session.pids: [Int]` (every record pid of the group, anchor first), `Session.tmuxPaneIndex: String?`; both init params with defaults.
- Produces: `enum CloseTarget: Equatable { case tmuxPane(id: String), herdrPane(id: String), terminalTab(tty: String), processOnly }`, `static func for(_ s: Session) -> CloseTarget` (tmuxPane > herdrPane > tty-not-in-tmux > processOnly), `func description(for s: Session) -> String` (alert/⌥ sentence).
- Produces: `Session.locationLine: String` — `tmux: main:2.1` / `tmux: main:2` / `herdr: w5:p1` / `Terminal tab` / `No terminal`.

- [ ] Write tests: parse 6-field and 5-field pane lines; builder test that a merged interactive+bg group yields `pids == [interactivePid, bgPid]`; `CloseTarget.for` for each of the four cases; `locationLine` for each of the five strings.
- [ ] Run `swift test` → new tests fail to compile.
- [ ] Implement.
- [ ] Run `swift test` → all pass.
- [ ] Commit `Core: close target, location line, session pids`.

### Task 2: Command process groups

**Files:** Modify `Sources/ClaudeLightsCore/ProcessTable.swift`; Test `ProcessTableTests.swift`.

**Interfaces:**
- Produces: `func claudeCommandGroups(claudePid: Int) -> [Int]` — sorted unique pgids of the `/shell-snapshots/snapshot-` children (the same filter as `claudeCommandCount`); `claudeCommandCount` reuses the filter.

- [ ] Test with the existing fixture: `claudeCommandGroups(claudePid: 800) == [810, 811]`, unknown pid → `[]`.
- [ ] Implement, run, commit `Core: process groups of a session's commands`.

### Task 3: Session summary

**Files:** Modify `Sources/ClaudeLightsCore/TranscriptReader.swift`; Test `Tests/ClaudeLightsCoreTests/SessionSummaryTests.swift`.

**Interfaces:**
- Produces: `struct SessionSummary: Equatable { enum Kind { case recap, lastPrompt }; let kind: Kind; let text: String; let date: Date? }`
- Produces: `TranscriptReader.sessionSummary(fromJSONLines:) -> SessionSummary?` (newest recap wins over any last-prompt; else newest last-prompt).
- Produces: `TranscriptReader.tailLines(of:maxBytes:)` decodes lossily (`String(decoding:as: UTF8.self)`).
- Produces: `TranscriptReader.wrap(_ s: String, width: Int = 50, maxLines: Int = 6) -> [String]`.

- [ ] Tests: recap present (text stripped of hint + `[2026-10-15]` and `` `2026-10-17` `` lines, date parsed from ISO-8601 with fractional seconds); only last-prompt; neither → nil; recap that is empty after stripping → falls back to last-prompt; `tailLines` on a file with invalid UTF-8 bytes still returns the JSON lines; `wrap` splits on spaces, hard-splits long CJK runs, caps at 6 lines with `…`.
- [ ] Implement, run, commit `Core: session summary from recap or last prompt`.

### Task 4: SessionCloser

**Files:** Create `Sources/ClaudeLights/SessionCloser.swift`.

**Interfaces:**
- Consumes: `CloseTarget.for`, `Session.pids`, `ProcessTable.claudeCommandGroups`, `Tmux.run`, `Herdr.run`.
- Produces: `final class SessionCloser { func close(_ s: Session) -> String? }` — blocking, call off main; returns an error sentence or nil.

Order: snapshot `ps` → for each live pid (registry check: `~/.claude/sessions/<pid>.json` exists and `sessionId == s.id`) collect command pgids → `SIGTERM` command groups and Claude pids → poll every 100 ms until all gone or 3 s → `SIGKILL` survivors (groups: `kill(-pgid, SIGKILL)`; `ESRCH` ignored) → remove container per `CloseTarget` (tab close via AppleScript: iTerm2 `close s` for matching session, Terminal `close t` for matching tab; only if the app runs). `EPERM` on a Claude pid → error.

- [ ] Implement; `swift build` passes.
- [ ] Commit with Task 5.

### Task 5: Confirmation + tray ⌥ alternate

**Files:** Modify `Sources/ClaudeLights/AppDelegate.swift`, `Sources/ClaudeLights/StatusItemController.swift`.

**Interfaces:**
- Produces: `StatusItemController.onCloseSession: ((Session) -> Void)?`; `FloatingBar.onCloseSession` (Task 6) wired to the same `AppDelegate.confirmClose(_:)`.

`confirmClose`: activate app, alert (title, body = `CloseTarget.description`, warning line for `.yellow` and/or `backgroundTasks > 0`), on Close run `SessionCloser.close` on a background queue, failure → `notifier.notifyInfo(title: "Close Session", body:)`.
⌥ alternate: same image, two-line attributed title (`Close “name”…` / description), `isAlternate`, `.option`.

- [ ] Implement; `scripts/bundle.sh` builds.
- [ ] Commit `Close a session from the tray menu (⌥)`.

### Task 6: Bar right-click menu

**Files:** Modify `Sources/ClaudeLights/FloatingBar.swift`.

Catch `rightMouseDown` in `FirstMouseHostingView`, map the click x to the dot index (dot frames recorded via the existing `HoverReporter` anchors), build an `NSMenu` (title, path → copies `cwd`, status, `locationLine`, version, summary block, `Close “name”…`) and `popUpContextMenu`. Summary read on open via `TranscriptReader`.

- [ ] Implement; build; manual check: right-click shows menu, left-click still jumps, drag still moves.
- [ ] Commit `Bar: right-click menu with session details and Close`.

### Task 7: Docs + end-to-end check

- [ ] CLAUDE.md Hard-won facts: one bullet on Close (pids group, command pgids collected before signalling, pane-only). Spec status → approved.
- [ ] Manual run per spec "Testing" with synthetic sessions.
- [ ] Commit `docs: close session`.
