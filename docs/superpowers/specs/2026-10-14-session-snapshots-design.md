# Session Snapshots (Save / Restore) Design

Date: 2026-10-14
Status: approved

## Goal

Save the layout of every running tmux session plus every Claude Code
session running outside tmux, and rebuild them later (typically after a
reboot) from the menu bar: windows, pane layouts, cwds, and
`claude --resume <id>` in each Claude pane.

This ports the standalone `~/bin/tmux-claude` Python script into the app.
Once shipped the script is retired; there is no command-line interface.

## Decisions (from brainstorming)

- **Swift rewrite inside the app**, not shelling out to the script.
- **UI is menu only:** a `Save Sessions` item and a `Restore ▸` submenu.
  No CLI.
- **Save scope:** every running tmux session (with or without Claude
  panes), plus all non-tmux Claude sessions combined into one synthetic
  snapshot named `claude-loose-sessions`.
- **Non-tmux sessions restore into tmux:** `claude-loose-sessions` is
  rebuilt as a real tmux session, one window per Claude session. Their
  original terminal app / tab grouping is not reproduced.
- **cwd is always recorded** for every pane and every loose session, and
  restore runs `cd <cwd> && claude --resume <id>`.
- **Storage in iCloud Drive, no local fallback:**
  `~/Library/Mobile Documents/com~apple~CloudDocs/ClaudeLights/sessions/<ComputerName>/`.
  One subfolder per Mac so machines never overwrite each other. Only the
  current Mac's folder is shown, because `claude --resume` needs the
  transcript under this Mac's `~/.claude/projects/`.
- **Background sessions (`kind:"bg"`) are not saved** — no window to
  restore. They are already excluded from `Session` lists.

## Non-goals

- Importing old snapshots from `~/.local/state/tmux-claude/sessions/`
  (the user can copy them into the iCloud folder by hand; the file
  format is compatible).
- Automatic / periodic saving.
- Restoring snapshots from other Macs.
- Reproducing the original terminal tabs of loose sessions.

## Snapshot file format

One JSON file per session, named `<percent-encoded session name>.json`,
written atomically (temp file + rename). Same shape as the script's
`version: 2`, so files stay interchangeable:

```json
{
  "version": 2,
  "saved_at": "2026-10-14T09:00:00-07:00",
  "session": {
    "name": "work",
    "path": "/Users/me/src",
    "windows": [{
      "index": 1, "name": "api", "automatic_rename": false,
      "layout": "b25f,200x50,0,0{100x50,0,0,1,99x50,101,0,2}",
      "width": 200, "height": 50, "active": true, "zoomed": false,
      "panes": [{
        "index": 0, "cwd": "/Users/me/src/api", "active": true,
        "claude": { "session_id": "…", "name": "…", "name_source": "…",
                    "cwd": "/Users/me/src/api", "status": "idle",
                    "version": "2.1.212" },
        "command": null
      }]
    }]
  }
}
```

- `claude` is null for a non-Claude pane; then `command` holds the
  pane's foreground command line (null when the shell is idle).
- `claude-loose-sessions`: `path` = home dir; one window per loose
  session, windows indexed from tmux `base-index`; window `name` =
  session title (`displayName`), `automatic_rename` false; one pane whose
  `cwd` and `claude.cwd` are the registry record's `cwd`; `layout` empty,
  width/height 200x50.

## Architecture

### Core (`ClaudeLightsCore`, unit-tested) — `Snapshot.swift`

Pure logic, no process or file I/O:

- `Snapshot` / `SnapshotWindow` / `SnapshotPane` / `SnapshotClaude`:
  `Codable` structs matching the JSON above (snake_case keys).
- `SnapshotCodec`: encode/decode the file envelope; file name ↔ session
  name (percent-encoding).
- `ProcessTable`: parse `ps -ax -o pid=,ppid=,pgid=,tpgid=,args=`;
  `foregroundCommand(shellPid:)` — same rule as the script (shell's
  children in the terminal's foreground process group, joined with
  ` | `).
- `SnapshotBuilder.all(...)`: the single entry point. Builds one snapshot
  per running tmux session (matching Claude panes to the app's `Session`s
  by tmux pane id, `Session.tmuxPane`, not a process-tree walk). Loose
  sessions (`tmuxSession == nil`) become windows of `claude-loose-sessions`;
  if tmux already runs a session of that name, the loose windows are
  appended to it rather than replacing it.
- `RestorePlan`, split in two because `base-index` can only be read once the
  server is up:
  - `newSession(_:)` — the `new-session` argument list. Run first.
  - `commands(_:baseIndex:)` — everything after (move-window, new-window,
    split-window, select-layout, rename-window, set-option
    automatic-rename, send-keys, select-pane, resize-pane -Z,
    select-window). User-supplied values follow a `--` guard. Resume line:
    `cd <shell-quoted cwd> && claude --resume <shell-quoted id>`.
    Non-Claude commands are typed with `send-keys -l` and no Enter.
  - `rebasedLoose(_:baseIndex:)` — renumbers a loose snapshot's windows from
    the server's base-index (it may have been saved while tmux was down,
    giving base 0).
- `SnapshotListing` / `SnapshotMenu` (`SnapshotMenu.swift`): listing of the
  folder (available / unreadable entries) and the pure mapping from
  listings + running names to menu entries and the restorable-name list.
- `SnapshotSummary`: menu label text, e.g.
  `work — 4 windows, 3 claude · saved 10-14 09:00`.

All tmux `-F` formats use `TmuxMapper.sep` (`|CL|`), never tab or `\x1f`.

### Shell (`ClaudeLights`) — `SnapshotStore.swift`, `SnapshotService.swift`

- `SnapshotStore`: resolves the folder (computer name from
  `SCDynamicStoreCopyComputerName`, `/` replaced with `-`), creates it,
  lists / reads / writes files. `read(name:)` makes the file name win over
  the name inside the JSON. Before reading, calls
  `FileManager.startDownloadingUbiquitousItem` for evicted iCloud
  placeholders (`.<name>.json.icloud`) and lists them as available.
- `SnapshotService`:
  - `saveAll(sessions:)` — runs `tmux list-sessions`, `list-windows -a`,
    `list-panes -a`, `show-options -gv base-index`, and `ps`; builds
    snapshots via `SnapshotBuilder.all`; writes one file per **running**
    tmux session plus loose (if any). Never deletes or touches files for
    sessions not running now.
  - `restore(names:)` — "running" means the name is in the `list-sessions`
    name set. Runs `RestorePlan.newSession` with a prepared server
    environment (login-shell `PATH`, UTF-8 `LANG`, since a Finder-launched
    app has neither and the server would pass that on to every shell), reads
    `base-index`, applies `rebasedLoose`, then runs `commands`. On failure
    it kills the session only if this restore created it
    (`kill-session -t =<name>`). Then opens a terminal window attached to it.
  - Menu entries are cached and refreshed on one serial background queue,
    so opening the menu never blocks on tmux or iCloud.
- `Jumper`: extract the window-opening half of `offerToOpenWindow` into
  `openTerminalWindow(attachingTo:)` (no alert) and reuse it.

### Menu (`StatusItemController`)

Placed below the session list, above `Show Light Bar`:

- `Save Sessions` — runs `saveAll` off the main thread; posts a
  notification: `Saved 3 tmux sessions + 2 loose sessions`.
- `Restore ▸` — rebuilt on menu open (existing NSMenuDelegate). One item
  per snapshot in this Mac's folder, sorted by name, labelled with
  `SnapshotSummary`. An item whose tmux session is already running is
  disabled and suffixed ` (running)`. Last item: `Restore All` (restores
  every non-running snapshot, one terminal window each). Empty folder →
  a single disabled `No saved sessions`.

## Error handling

- tmux missing or no server running: `Save` still writes the loose
  snapshot; tmux part is skipped and the notification says so.
- iCloud Drive unavailable (folder parent missing): notification
  `iCloud Drive is not available`; nothing written. No local fallback.
- Unreadable / corrupt snapshot file: shown disabled as
  `<name> (unreadable)`; never crash.
- A failing tmux command during restore: stop that session's restore,
  notify with the tmux stderr, continue with the next session.

## Testing

- Core unit tests (`swift test`):
  - Codec round-trip, and decoding a real file written by the Python
    script (fixture).
  - `ProcessTable` parsing and `foregroundCommand` (idle shell,
    single command, pipeline).
  - `SnapshotBuilder.tmux`: Claude pane matched by pane id; non-Claude
    pane gets `command`; multi-pane layout preserved.
  - `SnapshotBuilder.loose`: only `tmuxSession == nil` sessions; cwd
    and title carried; nil when empty.
  - `RestorePlan`: exact command list for single-window, multi-pane,
    zoomed, non-zero base-index, and loose snapshots; cwd with spaces is
    shell-quoted.
- Manual: save with a multi-pane tmux session + one iTerm2-tab Claude
  session; `tmux kill-server`; restore both from the menu; verify layout,
  cwds, and resumed conversations.
