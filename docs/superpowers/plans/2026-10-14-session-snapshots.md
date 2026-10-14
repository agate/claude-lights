# Session Snapshots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Menu-bar `Save Sessions` / `Restore ▸` that snapshot every tmux session plus all non-tmux Claude sessions into iCloud Drive and rebuild them as tmux sessions running `claude --resume <id>`.

**Architecture:** Pure snapshot logic (data model, JSON codec, `ps` parsing, tmux row parsing, snapshot building, restore command planning, menu labels) lives in `ClaudeLightsCore` and is unit-tested. The AppKit shell adds an iCloud-backed `SnapshotStore`, a `SnapshotService` that runs tmux/ps and executes restore plans, and menu items in `StatusItemController`.

**Tech Stack:** Swift 5.9 SwiftPM, XCTest, AppKit, tmux CLI, Foundation `NSFileCoordinator`.

**Spec:** `docs/superpowers/specs/2026-10-14-session-snapshots-design.md`

## Global Constraints

- Storage root: `~/Library/Mobile Documents/com~apple~CloudDocs/ClaudeLights/sessions/<ComputerName>/` — no local fallback.
- Computer name folder: `/` and `:` replaced with `-`.
- Loose snapshot name: `claude-loose-sessions`.
- File name: percent-encoded session name + `.json`, written atomically.
- File envelope: `{"version": 2, "saved_at": <ISO-8601 with offset>, "session": {...}}`, snake_case keys, `claude`/`command` encoded as explicit `null` when absent.
- Resume line: `cd <shell-quoted cwd> && claude --resume <shell-quoted id>`.
- Non-Claude pane commands are typed with `send-keys -l` and no Enter.
- All tmux `-F` formats use `TmuxMapper.sep` (`|CL|`).
- Save never deletes or rewrites files for sessions that are not running now.
- Restore skips a snapshot whose tmux session is already running; `Restore All` opens one terminal window per restored session.
- Background (`kind:"bg"`) sessions are never saved (already absent from `[Session]`).
- `swift test` must stay green after every task.

## Review Focus

1. A session whose registry has no `sessionId` (Session.id falls back to the pid string) — it cannot be resumed; it must be skipped, never written as `claude --resume <pid>`. Test in Task 3.
2. Save while a tmux session named `claude-loose-sessions` is already running (i.e. after a restore) plus new loose sessions — both must survive in one file (loose windows appended after the highest index), not one overwriting the other. Test in Task 3.
3. cwd or command containing spaces, `'`, `$` — must be shell-quoted in the resume line and `cd` line. Test in Task 4.
4. A restored loose window with `pane-base-index 1` — single-pane windows must be targeted by window (`name:idx`), not `name:idx.0`. Test in Task 4.
5. A corrupt / half-synced snapshot file or an iCloud placeholder — menu shows it disabled, never crashes. Test in Task 5.

---

### Task 1: Snapshot model + codec

**Files:**
- Create: `Sources/ClaudeLightsCore/Snapshot.swift`
- Test: `Tests/ClaudeLightsCoreTests/SnapshotCodecTests.swift`

**Interfaces:**
- Produces:
  - `public struct SnapshotClaude: Codable, Equatable { sessionId: String; name: String?; nameSource: String?; cwd: String?; status: String?; version: String? }`
  - `public struct SnapshotPane: Codable, Equatable { index: Int; cwd: String; active: Bool; claude: SnapshotClaude?; command: String? }`
  - `public struct SnapshotWindow: Codable, Equatable { index: Int; name: String; automaticRename: Bool; layout: String; width: Int; height: Int; active: Bool; zoomed: Bool; panes: [SnapshotPane] }`
  - `public struct Snapshot: Codable, Equatable { name: String; path: String; windows: [SnapshotWindow] }`
  - `public struct SnapshotFile: Codable, Equatable { version: Int; savedAt: String; session: Snapshot }`
  - `public enum SnapshotCodec { static let looseName: String; static func encode(_: SnapshotFile) throws -> Data; static func decode(_: Data) throws -> SnapshotFile; static func fileName(for name: String) -> String; static func sessionName(fromFileName: String) -> String?; static func folderName(computerName: String) -> String; static func timestamp(_ date: Date, timeZone: TimeZone) -> String }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ClaudeLightsCore

final class SnapshotCodecTests: XCTestCase {
    /// Written by the retired ~/bin/tmux-claude script (version 2).
    let scriptFixture = """
    {
      "version": 2,
      "saved_at": "2026-10-13T18:00:00-07:00",
      "session": {
        "name": "work",
        "path": "/Users/me/src",
        "windows": [
          {
            "index": 1, "name": "api", "automatic_rename": false,
            "layout": "b25f,200x50,0,0{100x50,0,0,1,99x50,101,0,2}",
            "width": 200, "height": 50, "active": true, "zoomed": false,
            "panes": [
              {"index": 0, "cwd": "/Users/me/src/api", "active": true,
               "claude": {"session_id": "abc", "name": "api-fix", "name_source": "auto",
                          "cwd": "/Users/me/src/api", "status": "idle", "version": "2.1.212"},
               "command": null},
              {"index": 1, "cwd": "/Users/me/src/api", "active": false,
               "claude": null, "command": "npm run dev"}
            ]
          }
        ]
      }
    }
    """

    func testDecodesScriptFile() throws {
        let file = try SnapshotCodec.decode(Data(scriptFixture.utf8))
        XCTAssertEqual(file.version, 2)
        XCTAssertEqual(file.savedAt, "2026-10-13T18:00:00-07:00")
        XCTAssertEqual(file.session.name, "work")
        let w = file.session.windows[0]
        XCTAssertFalse(w.automaticRename)
        XCTAssertEqual(w.panes[0].claude?.sessionId, "abc")
        XCTAssertEqual(w.panes[0].claude?.nameSource, "auto")
        XCTAssertNil(w.panes[1].claude)
        XCTAssertEqual(w.panes[1].command, "npm run dev")
    }

    func testRoundTripAndExplicitNulls() throws {
        let file = try SnapshotCodec.decode(Data(scriptFixture.utf8))
        let data = try SnapshotCodec.encode(file)
        XCTAssertEqual(try SnapshotCodec.decode(data), file)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"claude\" : null"), text)
        XCTAssertTrue(text.contains("\"command\" : null"), text)
        XCTAssertTrue(text.contains("\"saved_at\""), text)
        XCTAssertTrue(text.contains("\"session_id\""), text)
    }

    func testFileNameIsPercentEncodedAndReversible() {
        XCTAssertEqual(SnapshotCodec.fileName(for: "my work/x"), "my%20work%2Fx.json")
        XCTAssertEqual(SnapshotCodec.sessionName(fromFileName: "my%20work%2Fx.json"), "my work/x")
        XCTAssertNil(SnapshotCodec.sessionName(fromFileName: "notes.txt"))
        XCTAssertNil(SnapshotCodec.sessionName(fromFileName: ".work.json.icloud"))
    }

    func testFolderNameSanitizesSeparators() {
        XCTAssertEqual(SnapshotCodec.folderName(computerName: "Hao's Mac/Pro:2"), "Hao's Mac-Pro-2")
    }

    func testTimestampHasOffset() {
        let date = Date(timeIntervalSince1970: 1_760_403_600) // 2025-10-14T01:00:00Z
        let tz = TimeZone(secondsFromGMT: -7 * 3600)!
        XCTAssertEqual(SnapshotCodec.timestamp(date, timeZone: tz), "2025-10-13T18:00:00-07:00")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SnapshotCodecTests`
Expected: FAIL — compile error "cannot find 'SnapshotCodec' in scope".

- [ ] **Step 3: Implement `Sources/ClaudeLightsCore/Snapshot.swift`**

```swift
import Foundation

/// The Claude Code session that was running in a saved pane.
public struct SnapshotClaude: Codable, Equatable, Sendable {
    public var sessionId: String
    public var name: String?
    public var nameSource: String?
    public var cwd: String?
    public var status: String?
    public var version: String?

    public init(sessionId: String, name: String? = nil, nameSource: String? = nil,
                cwd: String? = nil, status: String? = nil, version: String? = nil) {
        self.sessionId = sessionId; self.name = name; self.nameSource = nameSource
        self.cwd = cwd; self.status = status; self.version = version
    }

    private enum CodingKeys: String, CodingKey { case sessionId, name, nameSource, cwd, status, version }

    // Explicit nulls (not omitted keys), matching files the old script wrote.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(name, forKey: .name)
        try c.encode(nameSource, forKey: .nameSource)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(status, forKey: .status)
        try c.encode(version, forKey: .version)
    }
}

public struct SnapshotPane: Codable, Equatable, Sendable {
    public var index: Int
    public var cwd: String
    public var active: Bool
    /// Set when the pane ran a resumable Claude session.
    public var claude: SnapshotClaude?
    /// Foreground command of a non-Claude pane; typed back on restore, not run.
    public var command: String?

    public init(index: Int, cwd: String, active: Bool, claude: SnapshotClaude? = nil,
                command: String? = nil) {
        self.index = index; self.cwd = cwd; self.active = active
        self.claude = claude; self.command = command
    }

    private enum CodingKeys: String, CodingKey { case index, cwd, active, claude, command }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(active, forKey: .active)
        try c.encode(claude, forKey: .claude)
        try c.encode(command, forKey: .command)
    }
}

public struct SnapshotWindow: Codable, Equatable, Sendable {
    public var index: Int
    public var name: String
    public var automaticRename: Bool
    public var layout: String
    public var width: Int
    public var height: Int
    public var active: Bool
    public var zoomed: Bool
    public var panes: [SnapshotPane]

    public init(index: Int, name: String, automaticRename: Bool, layout: String,
                width: Int, height: Int, active: Bool, zoomed: Bool, panes: [SnapshotPane]) {
        self.index = index; self.name = name; self.automaticRename = automaticRename
        self.layout = layout; self.width = width; self.height = height
        self.active = active; self.zoomed = zoomed; self.panes = panes
    }
}

public struct Snapshot: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var windows: [SnapshotWindow]

    public init(name: String, path: String, windows: [SnapshotWindow]) {
        self.name = name; self.path = path; self.windows = windows
    }
}

/// On-disk envelope; `version: 2` is the format the old tmux-claude script used.
public struct SnapshotFile: Codable, Equatable, Sendable {
    public var version: Int
    public var savedAt: String
    public var session: Snapshot

    public init(version: Int = 2, savedAt: String, session: Snapshot) {
        self.version = version; self.savedAt = savedAt; self.session = session
    }
}

public enum SnapshotCodec {
    /// Synthetic snapshot holding every Claude session that ran outside tmux.
    public static let looseName = "claude-loose-sessions"

    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    public static func encode(_ file: SnapshotFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    public static func decode(_ data: Data) throws -> SnapshotFile {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SnapshotFile.self, from: data)
    }

    public static func fileName(for name: String) -> String {
        (name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name) + ".json"
    }

    /// Session name for a snapshot file, or nil for anything else
    /// (including iCloud placeholders like `.work.json.icloud`).
    public static func sessionName(fromFileName file: String) -> String? {
        guard file.hasSuffix(".json"), !file.hasPrefix(".") else { return nil }
        return String(file.dropLast(5)).removingPercentEncoding
    }

    public static func folderName(computerName: String) -> String {
        computerName.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    /// ISO-8601 with a numeric offset, e.g. "2026-10-14T09:00:00-07:00".
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
```

Note: `ISO8601DateFormatter` prints `Z` for a zero offset; that is fine (`-07:00` style otherwise).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SnapshotCodecTests`
Expected: PASS (5 tests). If `testRoundTripAndExplicitNulls` fails on spacing, check the exact pretty-print form (`"claude" : null`) in the failure output and adjust only the assertion string.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeLightsCore/Snapshot.swift Tests/ClaudeLightsCoreTests/SnapshotCodecTests.swift
git commit -m "feat: add session snapshot model and JSON codec"
```

---

### Task 2: Process table (foreground command of a pane)

**Files:**
- Create: `Sources/ClaudeLightsCore/ProcessTable.swift`
- Test: `Tests/ClaudeLightsCoreTests/ProcessTableTests.swift`

**Interfaces:**
- Produces:
  - `public struct ProcessTable { public static let psArguments: [String]; public static func parse(_ output: String) -> ProcessTable; public func foregroundCommand(shellPid: Int) -> String? }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ClaudeLightsCore

final class ProcessTableTests: XCTestCase {
    // pid ppid pgid tpgid args
    let fixture = """
      100     1   100   100 -zsh
      200     1   200   300 -zsh
      300   200   300   300 tail -f log.txt
      301   200   300   300 grep error
      400     1   400   500 -zsh
      500   400   500   500 npm run dev
      501   500   500   500 node server.js
      600     1   600     0 -zsh
    """

    func testIdleShellHasNoCommand() {
        let t = ProcessTable.parse(fixture)
        XCTAssertNil(t.foregroundCommand(shellPid: 100)) // tpgid == own pgid
        XCTAssertNil(t.foregroundCommand(shellPid: 600)) // no controlling terminal group
        XCTAssertNil(t.foregroundCommand(shellPid: 999)) // unknown pid
    }

    func testPipelineJoinedInPidOrder() {
        let t = ProcessTable.parse(fixture)
        XCTAssertEqual(t.foregroundCommand(shellPid: 200), "tail -f log.txt | grep error")
    }

    func testOnlyDirectChildrenCount() {
        let t = ProcessTable.parse(fixture)
        XCTAssertEqual(t.foregroundCommand(shellPid: 400), "npm run dev")
    }

    func testSkipsMalformedLines() {
        let t = ProcessTable.parse("garbage\n  7 1 7 7 vim\n")
        XCTAssertNil(t.foregroundCommand(shellPid: 7))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProcessTableTests`
Expected: FAIL — "cannot find 'ProcessTable' in scope".

- [ ] **Step 3: Implement `Sources/ClaudeLightsCore/ProcessTable.swift`**

```swift
import Foundation

/// Snapshot of `ps -ax -o pid=,ppid=,pgid=,tpgid=,args=`.
public struct ProcessTable: Sendable {
    public static let psArguments = ["-ax", "-o", "pid=,ppid=,pgid=,tpgid=,args="]

    struct Proc: Sendable { let pgid: Int; let tpgid: Int; let args: String; var children: [Int] }
    private(set) var procs: [Int: Proc] = [:]

    public static func parse(_ output: String) -> ProcessTable {
        var table = ProcessTable()
        var parents: [Int: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int(parts[0]), let ppid = Int(parts[1]),
                  let pgid = Int(parts[2]), let tpgid = Int(parts[3]) else { continue }
            let args = parts.count > 4 ? String(parts[4]) : ""
            table.procs[pid] = Proc(pgid: pgid, tpgid: tpgid, args: args, children: [])
            parents[pid] = ppid
        }
        for (pid, ppid) in parents where table.procs[ppid] != nil {
            table.procs[ppid]?.children.append(pid)
        }
        return table
    }

    /// Command line in the foreground of a pane's shell, or nil when the
    /// shell is idle. The shell's direct children in the terminal's
    /// foreground process group are joined with " | ", so a pipeline comes
    /// back whole. `ps` does not keep the original quoting.
    public func foregroundCommand(shellPid: Int) -> String? {
        guard let shell = procs[shellPid],
              shell.tpgid > 0, shell.tpgid != shell.pgid else { return nil }
        let fg = shell.tpgid
        var members = shell.children.filter { procs[$0]?.pgid == fg }.sorted()
        if members.isEmpty, procs[fg] != nil { members = [fg] }
        let line = members.compactMap { procs[$0]?.args }.joined(separator: " | ")
        return line.isEmpty ? nil : line
    }
}
```

Note: `testSkipsMalformedLines` — pid 7 is its own pgid/tpgid (idle), so nil is expected; the test proves the "garbage" line did not crash parsing.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProcessTableTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeLightsCore/ProcessTable.swift Tests/ClaudeLightsCoreTests/ProcessTableTests.swift
git commit -m "feat: parse the process table to find a pane's foreground command"
```

---

### Task 3: tmux row parsing + snapshot building

**Files:**
- Create: `Sources/ClaudeLightsCore/SnapshotBuilder.swift`
- Test: `Tests/ClaudeLightsCoreTests/SnapshotBuilderTests.swift`

**Interfaces:**
- Consumes: `Snapshot*` (Task 1), `ProcessTable` (Task 2), `Session` and `TmuxMapper.sep` (existing).
- Produces:
  - `public struct SnapshotTmux` with `static let sessionsFormat, windowsFormat, panesFormat: String` and parsers `parseSessions(_:) -> [SessionRow]`, `parseWindows(_:) -> [WindowRow]`, `parsePanes(_:) -> [PaneRow]`.
  - `SnapshotTmux.SessionRow { name: String; path: String }`
  - `SnapshotTmux.WindowRow { session: String; index: Int; name: String; layout: String; active: Bool; zoomed: Bool; width: Int; height: Int; automaticRename: Bool }`
  - `SnapshotTmux.PaneRow { session: String; windowIndex: Int; index: Int; paneId: String; pid: Int; cwd: String; active: Bool }`
  - `public enum SnapshotBuilder { static func all(tmuxSessions: [SessionRow], windows: [WindowRow], panes: [PaneRow], sessions: [Session], procs: ProcessTable, home: String, baseIndex: Int) -> [Snapshot]; static func isResumable(_ s: Session) -> Bool }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ClaudeLightsCore

final class SnapshotBuilderTests: XCTestCase {
    let sep = TmuxMapper.sep

    func session(id: String, pid: Int, cwd: String, tmuxPane: String? = nil,
                 tmuxSession: String? = nil, title: String? = nil,
                 startedAt: Double = 0) -> Session {
        Session(id: id, pid: pid, cwd: cwd, projectName: (cwd as NSString).lastPathComponent,
                derivedName: "derived-\(id)", light: .green, statusText: "Idle",
                statusUpdatedAt: nil, tmuxSession: tmuxSession,
                tmuxWindow: tmuxSession == nil ? nil : "1", tmuxPane: tmuxPane,
                title: title, version: "2.1.212", startedAt: startedAt)
    }

    func testParsesTmuxRows() {
        let s = SnapshotTmux.parseSessions("work\(sep)/Users/me/src\n")
        XCTAssertEqual(s, [.init(name: "work", path: "/Users/me/src")])
        let w = SnapshotTmux.parseWindows(
            "work\(sep)1\(sep)api\(sep)b25f,200x50\(sep)1\(sep)0\(sep)200\(sep)50\(sep)off\n")
        XCTAssertEqual(w, [.init(session: "work", index: 1, name: "api", layout: "b25f,200x50",
                                 active: true, zoomed: false, width: 200, height: 50,
                                 automaticRename: false)])
        let p = SnapshotTmux.parsePanes(
            "work\(sep)1\(sep)0\(sep)%3\(sep)200\(sep)/Users/me/src/api\(sep)1\n")
        XCTAssertEqual(p, [.init(session: "work", windowIndex: 1, index: 0, paneId: "%3",
                                 pid: 200, cwd: "/Users/me/src/api", active: true)])
    }

    func testEmptyAutomaticRenameMeansOn() {
        let w = SnapshotTmux.parseWindows("work\(sep)1\(sep)api\(sep)l\(sep)1\(sep)0\(sep)80\(sep)24\(sep)\n")
        XCTAssertEqual(w.first?.automaticRename, true)
    }

    func testTmuxSnapshotMatchesClaudeByPaneIdAndCapturesCommands() {
        let procs = ProcessTable.parse("""
          200 1 200 200 -zsh
          201 1 201 202 -zsh
          202 201 202 202 npm run dev
        """)
        let snaps = SnapshotBuilder.all(
            tmuxSessions: [.init(name: "work", path: "/src")],
            windows: [.init(session: "work", index: 1, name: "api", layout: "L", active: true,
                            zoomed: false, width: 200, height: 50, automaticRename: false)],
            panes: [
                .init(session: "work", windowIndex: 1, index: 0, paneId: "%3", pid: 200,
                      cwd: "/src/api", active: true),
                .init(session: "work", windowIndex: 1, index: 1, paneId: "%4", pid: 201,
                      cwd: "/src/api", active: false),
            ],
            sessions: [session(id: "abc", pid: 300, cwd: "/src/api", tmuxPane: "%3",
                               tmuxSession: "work")],
            procs: procs, home: "/Users/me", baseIndex: 0)
        XCTAssertEqual(snaps.count, 1)
        let w = snaps[0].windows[0]
        XCTAssertEqual(snaps[0].path, "/src")
        XCTAssertEqual(w.layout, "L")
        XCTAssertEqual(w.panes[0].claude?.sessionId, "abc")
        XCTAssertEqual(w.panes[0].claude?.cwd, "/src/api")
        XCTAssertNil(w.panes[0].command)
        XCTAssertNil(w.panes[1].claude)
        XCTAssertEqual(w.panes[1].command, "npm run dev")
    }

    func testTmuxSessionWithoutClaudeIsStillSaved() {
        let snaps = SnapshotBuilder.all(
            tmuxSessions: [.init(name: "misc", path: "/")],
            windows: [.init(session: "misc", index: 0, name: "zsh", layout: "L", active: true,
                            zoomed: false, width: 80, height: 24, automaticRename: true)],
            panes: [.init(session: "misc", windowIndex: 0, index: 0, paneId: "%0", pid: 1,
                          cwd: "/tmp", active: true)],
            sessions: [], procs: ProcessTable.parse(""), home: "/Users/me", baseIndex: 0)
        XCTAssertEqual(snaps.map(\.name), ["misc"])
    }

    func testLooseSnapshotFromNonTmuxSessionsKeepsCwdAndTitle() {
        let snaps = SnapshotBuilder.all(
            tmuxSessions: [], windows: [], panes: [],
            sessions: [
                session(id: "b", pid: 2, cwd: "/Users/me/b", startedAt: 2),
                session(id: "a", pid: 1, cwd: "/Users/me/a", title: "Fix login", startedAt: 1),
            ],
            procs: ProcessTable.parse(""), home: "/Users/me", baseIndex: 1)
        XCTAssertEqual(snaps.count, 1)
        let loose = snaps[0]
        XCTAssertEqual(loose.name, SnapshotCodec.looseName)
        XCTAssertEqual(loose.path, "/Users/me")
        // Ordered by launch time, indexed from base-index.
        XCTAssertEqual(loose.windows.map(\.index), [1, 2])
        XCTAssertEqual(loose.windows.map(\.name), ["Fix login", "b"])
        XCTAssertEqual(loose.windows[0].panes[0].cwd, "/Users/me/a")
        XCTAssertEqual(loose.windows[0].panes[0].claude?.cwd, "/Users/me/a")
        XCTAssertEqual(loose.windows[0].panes[0].claude?.sessionId, "a")
        XCTAssertFalse(loose.windows[0].automaticRename)
        XCTAssertTrue(loose.windows[0].active)
        XCTAssertFalse(loose.windows[1].active)
    }

    func testNoLooseSnapshotWhenNothingLoose() {
        let snaps = SnapshotBuilder.all(tmuxSessions: [], windows: [], panes: [], sessions: [],
                                        procs: ProcessTable.parse(""), home: "/h", baseIndex: 0)
        XCTAssertTrue(snaps.isEmpty)
    }

    // Review Focus 1
    func testSessionWithoutSessionIdIsNotResumable() {
        // SessionBuilder falls back to the pid string when sessionId is missing.
        let s = session(id: "42", pid: 42, cwd: "/x")
        XCTAssertFalse(SnapshotBuilder.isResumable(s))
        let snaps = SnapshotBuilder.all(tmuxSessions: [], windows: [], panes: [], sessions: [s],
                                        procs: ProcessTable.parse(""), home: "/h", baseIndex: 0)
        XCTAssertTrue(snaps.isEmpty)
    }

    // Review Focus 2
    func testLooseWindowsAppendToRunningLooseTmuxSession() {
        let snaps = SnapshotBuilder.all(
            tmuxSessions: [.init(name: SnapshotCodec.looseName, path: "/Users/me")],
            windows: [.init(session: SnapshotCodec.looseName, index: 3, name: "old", layout: "L",
                            active: true, zoomed: false, width: 80, height: 24,
                            automaticRename: false)],
            panes: [.init(session: SnapshotCodec.looseName, windowIndex: 3, index: 0, paneId: "%9",
                          pid: 9, cwd: "/Users/me/old", active: true)],
            sessions: [session(id: "old", pid: 90, cwd: "/Users/me/old", tmuxPane: "%9",
                               tmuxSession: SnapshotCodec.looseName),
                       session(id: "new", pid: 91, cwd: "/Users/me/new")],
            procs: ProcessTable.parse(""), home: "/Users/me", baseIndex: 0)
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps[0].windows.map(\.index), [3, 4])
        XCTAssertEqual(snaps[0].windows.map { $0.panes[0].claude?.sessionId }, ["old", "new"])
        XCTAssertFalse(snaps[0].windows[1].active) // the running session keeps its active window
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SnapshotBuilderTests`
Expected: FAIL — "cannot find 'SnapshotTmux' in scope".

- [ ] **Step 3: Implement `Sources/ClaudeLightsCore/SnapshotBuilder.swift`**

```swift
import Foundation

/// tmux `-F` formats and parsers for capturing a snapshot.
public enum SnapshotTmux {
    private static let sep = TmuxMapper.sep

    public struct SessionRow: Equatable, Sendable {
        public let name: String; public let path: String
        public init(name: String, path: String) { self.name = name; self.path = path }
    }

    public struct WindowRow: Equatable, Sendable {
        public let session: String; public let index: Int; public let name: String
        public let layout: String; public let active: Bool; public let zoomed: Bool
        public let width: Int; public let height: Int; public let automaticRename: Bool
        public init(session: String, index: Int, name: String, layout: String, active: Bool,
                    zoomed: Bool, width: Int, height: Int, automaticRename: Bool) {
            self.session = session; self.index = index; self.name = name; self.layout = layout
            self.active = active; self.zoomed = zoomed; self.width = width; self.height = height
            self.automaticRename = automaticRename
        }
    }

    public struct PaneRow: Equatable, Sendable {
        public let session: String; public let windowIndex: Int; public let index: Int
        public let paneId: String; public let pid: Int; public let cwd: String
        public let active: Bool
        public init(session: String, windowIndex: Int, index: Int, paneId: String, pid: Int,
                    cwd: String, active: Bool) {
            self.session = session; self.windowIndex = windowIndex; self.index = index
            self.paneId = paneId; self.pid = pid; self.cwd = cwd; self.active = active
        }
    }

    /// `tmux list-sessions -F`
    public static let sessionsFormat = "#{session_name}\(sep)#{session_path}"
    /// `tmux list-windows -a -F`. `#{automatic-rename}` is the effective option value.
    public static let windowsFormat = [
        "#{session_name}", "#{window_index}", "#{window_name}", "#{window_layout}",
        "#{window_active}", "#{window_zoomed_flag}", "#{window_width}", "#{window_height}",
        "#{automatic-rename}",
    ].joined(separator: sep)
    /// `tmux list-panes -a -F`
    public static let panesFormat = [
        "#{session_name}", "#{window_index}", "#{pane_index}", "#{pane_id}", "#{pane_pid}",
        "#{pane_current_path}", "#{pane_active}",
    ].joined(separator: sep)

    private static func rows(_ output: String, count: Int) -> [[String]] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: sep)
            return parts.count == count ? parts : nil
        }
    }

    public static func parseSessions(_ output: String) -> [SessionRow] {
        rows(output, count: 2).map { SessionRow(name: $0[0], path: $0[1]) }
    }

    public static func parseWindows(_ output: String) -> [WindowRow] {
        rows(output, count: 9).compactMap { f in
            guard let index = Int(f[1]), let w = Int(f[6]), let h = Int(f[7]) else { return nil }
            // Empty means the option is unset, which tmux treats as on.
            return WindowRow(session: f[0], index: index, name: f[2], layout: f[3],
                             active: f[4] == "1", zoomed: f[5] == "1", width: w, height: h,
                             automaticRename: f[8] != "off" && f[8] != "0")
        }
    }

    public static func parsePanes(_ output: String) -> [PaneRow] {
        rows(output, count: 7).compactMap { f in
            guard let w = Int(f[1]), let i = Int(f[2]), let pid = Int(f[4]) else { return nil }
            return PaneRow(session: f[0], windowIndex: w, index: i, paneId: f[3], pid: pid,
                           cwd: f[5], active: f[6] == "1")
        }
    }
}

public enum SnapshotBuilder {
    /// Default size for windows of the loose snapshot (they have no tmux size yet).
    static let looseSize = (width: 200, height: 50)

    /// SessionBuilder falls back to the pid as id when the registry has no
    /// sessionId; such a session cannot be resumed.
    public static func isResumable(_ s: Session) -> Bool { s.id != String(s.pid) }

    static func claude(for s: Session) -> SnapshotClaude {
        SnapshotClaude(sessionId: s.id, name: s.derivedName.isEmpty ? s.title : s.derivedName,
                       nameSource: nil, cwd: s.cwd, status: s.statusText, version: s.version)
    }

    /// One snapshot per running tmux session, plus the loose snapshot for
    /// resumable Claude sessions outside tmux. When a tmux session named
    /// `claude-loose-sessions` is already running, loose windows are
    /// appended to it instead of producing a second snapshot of that name.
    public static func all(tmuxSessions: [SnapshotTmux.SessionRow],
                           windows: [SnapshotTmux.WindowRow],
                           panes: [SnapshotTmux.PaneRow],
                           sessions: [Session],
                           procs: ProcessTable,
                           home: String,
                           baseIndex: Int) -> [Snapshot] {
        let byPane = Dictionary(
            sessions.compactMap { s in s.tmuxPane.map { ($0, s) } }.filter { isResumable($0.1) },
            uniquingKeysWith: { first, _ in first })
        var snaps = tmuxSessions.map { row -> Snapshot in
            let ws = windows.filter { $0.session == row.name }.sorted { $0.index < $1.index }.map { w in
                let ps = panes.filter { $0.session == row.name && $0.windowIndex == w.index }
                    .sorted { $0.index < $1.index }
                    .map { p -> SnapshotPane in
                        if let s = byPane[p.paneId] {
                            return SnapshotPane(index: p.index, cwd: p.cwd, active: p.active,
                                                claude: claude(for: s))
                        }
                        return SnapshotPane(index: p.index, cwd: p.cwd, active: p.active,
                                            command: procs.foregroundCommand(shellPid: p.pid))
                    }
                return SnapshotWindow(index: w.index, name: w.name, automaticRename: w.automaticRename,
                                      layout: w.layout, width: w.width, height: w.height,
                                      active: w.active, zoomed: w.zoomed, panes: ps)
            }
            return Snapshot(name: row.name, path: row.path, windows: ws)
        }

        let loose = sessions.filter { $0.tmuxSession == nil && isResumable($0) }
            .sorted { ($0.startedAt ?? 0, $0.id) < ($1.startedAt ?? 0, $1.id) }
        guard !loose.isEmpty else { return snaps }
        if let i = snaps.firstIndex(where: { $0.name == SnapshotCodec.looseName }) {
            let next = (snaps[i].windows.map(\.index).max() ?? (baseIndex - 1)) + 1
            snaps[i].windows += looseWindows(loose, firstIndex: next, firstActive: false)
        } else {
            snaps.append(Snapshot(name: SnapshotCodec.looseName, path: home,
                                  windows: looseWindows(loose, firstIndex: baseIndex,
                                                        firstActive: true)))
        }
        return snaps
    }

    static func looseWindows(_ sessions: [Session], firstIndex: Int,
                             firstActive: Bool) -> [SnapshotWindow] {
        sessions.enumerated().map { i, s in
            SnapshotWindow(index: firstIndex + i, name: s.displayName, automaticRename: false,
                           layout: "", width: looseSize.width, height: looseSize.height,
                           active: firstActive && i == 0, zoomed: false,
                           panes: [SnapshotPane(index: 0, cwd: s.cwd, active: true,
                                                claude: claude(for: s))])
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SnapshotBuilderTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeLightsCore/SnapshotBuilder.swift Tests/ClaudeLightsCoreTests/SnapshotBuilderTests.swift
git commit -m "feat: build session snapshots from tmux rows and non-tmux sessions"
```

---

### Task 4: Restore plan (snapshot → tmux commands)

**Files:**
- Create: `Sources/ClaudeLightsCore/RestorePlan.swift`
- Test: `Tests/ClaudeLightsCoreTests/RestorePlanTests.swift`

**Interfaces:**
- Consumes: `Snapshot*` (Task 1).
- Produces:
  - `public enum RestorePlan { static func newSession(_ s: Snapshot) -> [String]; static func commands(_ s: Snapshot, baseIndex: Int) -> [[String]]; static func resumeLine(_ pane: SnapshotPane) -> String?; static func shellQuote(_ s: String) -> String }`
  - Contract: the caller runs `newSession` first (so a tmux server exists), reads `show-options -gv base-index`, then runs every element of `commands` in order.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ClaudeLightsCore

final class RestorePlanTests: XCTestCase {
    func pane(_ i: Int, _ cwd: String, active: Bool = false, claude: String? = nil,
              command: String? = nil) -> SnapshotPane {
        SnapshotPane(index: i, cwd: cwd, active: active,
                     claude: claude.map { SnapshotClaude(sessionId: $0, cwd: cwd) },
                     command: command)
    }

    func testShellQuote() {
        XCTAssertEqual(RestorePlan.shellQuote("/Users/me/src"), "/Users/me/src")
        XCTAssertEqual(RestorePlan.shellQuote("/Users/me/my src"), "'/Users/me/my src'")
        XCTAssertEqual(RestorePlan.shellQuote("it's $HOME"), "'it'\"'\"'s $HOME'")
        XCTAssertEqual(RestorePlan.shellQuote(""), "''")
    }

    // Review Focus 3
    func testResumeLineQuotesCwdAndPrefersClaudeCwd() {
        var p = pane(0, "/pane cwd", claude: "abc")
        p.claude?.cwd = "/Users/me/it's here"
        XCTAssertEqual(RestorePlan.resumeLine(p),
                       "cd '/Users/me/it'\"'\"'s here' && claude --resume abc")
        p.claude?.cwd = nil
        XCTAssertEqual(RestorePlan.resumeLine(p), "cd '/pane cwd' && claude --resume abc")
        XCTAssertNil(RestorePlan.resumeLine(pane(0, "/x")))
    }

    func testNewSession() {
        let s = Snapshot(name: "work", path: "/src", windows: [
            SnapshotWindow(index: 1, name: "a", automaticRename: true, layout: "", width: 120,
                           height: 40, active: true, zoomed: false, panes: [pane(0, "/src")]),
        ])
        XCTAssertEqual(RestorePlan.newSession(s),
                       ["new-session", "-d", "-s", "work", "-c", "/src", "-x", "120", "-y", "40"])
    }

    func testMultiWindowMultiPaneZoomed() {
        let s = Snapshot(name: "work", path: "/src", windows: [
            SnapshotWindow(index: 1, name: "api", automaticRename: false, layout: "LAYOUT",
                           width: 200, height: 50, active: false, zoomed: true,
                           panes: [pane(0, "/src/api", claude: "abc"),
                                   pane(1, "/src/api", active: true, command: "npm run dev")]),
            SnapshotWindow(index: 2, name: "zsh", automaticRename: true, layout: "L2",
                           width: 200, height: 50, active: true, zoomed: false,
                           panes: [pane(0, "/src/web", active: true)]),
        ])
        XCTAssertEqual(RestorePlan.commands(s, baseIndex: 0), [
            ["move-window", "-s", "work:0", "-t", "work:1"],
            ["send-keys", "-t", "work:1", "cd /src/api && clear", "Enter"],
            ["split-window", "-d", "-t", "work:1", "-c", "/src/api"],
            ["select-layout", "-t", "work:1", "LAYOUT"],
            ["rename-window", "-t", "work:1", "api"],
            ["set-option", "-w", "-t", "work:1", "automatic-rename", "off"],
            ["send-keys", "-t", "work:1.0", "cd /src/api && claude --resume abc", "Enter"],
            ["send-keys", "-t", "work:1.1", "-l", "npm run dev"],
            ["select-pane", "-t", "work:1.1"],
            ["resize-pane", "-Z", "-t", "work:1"],
            ["new-window", "-d", "-t", "work:2", "-c", "/src/web"],
            ["rename-window", "-t", "work:2", "zsh"],
            ["set-option", "-w", "-t", "work:2", "automatic-rename", "on"],
            ["select-window", "-t", "work:2"],
        ])
    }

    func testNoMoveWhenFirstIndexMatchesBase() {
        let s = Snapshot(name: "w", path: "/src", windows: [
            SnapshotWindow(index: 1, name: "a", automaticRename: true, layout: "", width: 80,
                           height: 24, active: true, zoomed: false, panes: [pane(0, "/src")]),
        ])
        XCTAssertEqual(RestorePlan.commands(s, baseIndex: 1), [
            ["rename-window", "-t", "w:1", "a"],
            ["set-option", "-w", "-t", "w:1", "automatic-rename", "on"],
            ["select-window", "-t", "w:1"],
        ])
    }

    // Review Focus 4: single-pane windows are targeted by window, so
    // pane-base-index never matters for the loose snapshot.
    func testSinglePaneWindowTargetsWindowNotPaneIndex() {
        let s = Snapshot(name: SnapshotCodec.looseName, path: "/Users/me", windows: [
            SnapshotWindow(index: 1, name: "Fix login", automaticRename: false, layout: "",
                           width: 200, height: 50, active: true, zoomed: false,
                           panes: [pane(0, "/Users/me/a b", active: true, claude: "s1")]),
        ])
        let cmds = RestorePlan.commands(s, baseIndex: 1)
        XCTAssertTrue(cmds.contains(["send-keys", "-t", "claude-loose-sessions:1",
                                     "cd '/Users/me/a b' && claude --resume s1", "Enter"]), "\(cmds)")
        XCTAssertFalse(cmds.contains { $0.first == "select-pane" })
        XCTAssertFalse(cmds.contains { $0.contains { $0.hasSuffix(":1.0") } })
        // First window's cwd differs from session path, but the resume line cds itself;
        // the extra "cd && clear" still runs first and is harmless.
        XCTAssertEqual(cmds.first, ["send-keys", "-t", "claude-loose-sessions:1",
                                    "cd '/Users/me/a b' && clear", "Enter"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RestorePlanTests`
Expected: FAIL — "cannot find 'RestorePlan' in scope".

- [ ] **Step 3: Implement `Sources/ClaudeLightsCore/RestorePlan.swift`**

```swift
import Foundation

/// Turns a snapshot into the ordered tmux commands that rebuild it.
public enum RestorePlan {
    /// Creates the session (and the tmux server, if none runs). Run first.
    public static func newSession(_ s: Snapshot) -> [String] {
        let first = s.windows.first
        return ["new-session", "-d", "-s", s.name, "-c", s.path,
                "-x", String(first?.width ?? 200), "-y", String(first?.height ?? 50)]
    }

    /// Everything after `newSession`. `baseIndex` is the server's
    /// `base-index`, i.e. the index new-session gave the first window.
    public static func commands(_ s: Snapshot, baseIndex: Int) -> [[String]] {
        var out: [[String]] = []
        for (i, w) in s.windows.enumerated() {
            let target = "\(s.name):\(w.index)"
            let startCwd = w.panes.first?.cwd ?? s.path
            if i == 0 {
                if w.index != baseIndex {
                    out.append(["move-window", "-s", "\(s.name):\(baseIndex)", "-t", target])
                }
                if startCwd != s.path {
                    out.append(["send-keys", "-t", target, "cd \(shellQuote(startCwd)) && clear", "Enter"])
                }
            } else {
                out.append(["new-window", "-d", "-t", target, "-c", startCwd])
            }
            for p in w.panes.dropFirst() {
                out.append(["split-window", "-d", "-t", target, "-c", p.cwd])
            }
            let multi = w.panes.count > 1
            if multi { out.append(["select-layout", "-t", target, w.layout]) }
            out.append(["rename-window", "-t", target, w.name])
            out.append(["set-option", "-w", "-t", target, "automatic-rename",
                        w.automaticRename ? "on" : "off"])
            for p in w.panes {
                // A lone pane is addressed by its window, so pane-base-index never matters.
                let pane = multi ? "\(target).\(p.index)" : target
                if let line = resumeLine(p) {
                    out.append(["send-keys", "-t", pane, line, "Enter"])
                } else if let cmd = p.command {
                    // Typed but not run: the user reviews it and presses Enter.
                    out.append(["send-keys", "-t", pane, "-l", cmd])
                }
            }
            if multi, let active = w.panes.first(where: \.active) {
                out.append(["select-pane", "-t", "\(target).\(active.index)"])
            }
            if w.zoomed { out.append(["resize-pane", "-Z", "-t", target]) }
        }
        if let active = s.windows.first(where: \.active) {
            out.append(["select-window", "-t", "\(s.name):\(active.index)"])
        }
        return out
    }

    public static func resumeLine(_ pane: SnapshotPane) -> String? {
        guard let c = pane.claude else { return nil }
        let cwd = c.cwd ?? pane.cwd
        return "cd \(shellQuote(cwd)) && claude --resume \(shellQuote(c.sessionId))"
    }

    /// POSIX shell quoting, same rules as Python's shlex.quote.
    public static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RestorePlanTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeLightsCore/RestorePlan.swift Tests/ClaudeLightsCoreTests/RestorePlanTests.swift
git commit -m "feat: plan the tmux commands that rebuild a saved session"
```

---

### Task 5: Menu entries for snapshots

**Files:**
- Create: `Sources/ClaudeLightsCore/SnapshotMenu.swift`
- Test: `Tests/ClaudeLightsCoreTests/SnapshotMenuTests.swift`

**Interfaces:**
- Consumes: `SnapshotFile` (Task 1).
- Produces:
  - `public enum SnapshotListing: Equatable { case ready(SnapshotFile); case downloading(String); case unreadable(String) }` with `var name: String`.
  - `public struct SnapshotMenuEntry: Equatable { title: String; restoreName: String?; enabled: Bool }`
  - `public enum SnapshotMenu { static func entries(_ listings: [SnapshotListing], running: Set<String>, timeZone: TimeZone) -> [SnapshotMenuEntry]; static func summary(_ file: SnapshotFile, timeZone: TimeZone) -> String; static func restorableNames(_ listings: [SnapshotListing], running: Set<String>) -> [String] }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ClaudeLightsCore

final class SnapshotMenuTests: XCTestCase {
    let tz = TimeZone(secondsFromGMT: -7 * 3600)!

    func file(_ name: String, windows: Int, claudes: Int) -> SnapshotFile {
        let ws = (0..<windows).map { i in
            SnapshotWindow(index: i, name: "w\(i)", automaticRename: true, layout: "", width: 80,
                           height: 24, active: i == 0, zoomed: false,
                           panes: [SnapshotPane(index: 0, cwd: "/", active: true,
                                                claude: i < claudes ? SnapshotClaude(sessionId: "s\(i)") : nil)])
        }
        return SnapshotFile(savedAt: "2026-10-14T09:00:00-07:00",
                            session: Snapshot(name: name, path: "/", windows: ws))
    }

    func testSummary() {
        XCTAssertEqual(SnapshotMenu.summary(file("work", windows: 4, claudes: 3), timeZone: tz),
                       "work — 4 windows, 3 claude · saved 10-14 09:00")
        XCTAssertEqual(SnapshotMenu.summary(file("blog", windows: 1, claudes: 1), timeZone: tz),
                       "blog — 1 window, 1 claude · saved 10-14 09:00")
    }

    func testEntriesSortedRunningDisabledAndRestoreAll() {
        let e = SnapshotMenu.entries([.ready(file("work", windows: 1, claudes: 1)),
                                      .ready(file("blog", windows: 1, claudes: 1))],
                                     running: ["work"], timeZone: tz)
        XCTAssertEqual(e.map(\.title), [
            "blog — 1 window, 1 claude · saved 10-14 09:00",
            "work — 1 window, 1 claude · saved 10-14 09:00 (running)",
            "Restore All",
        ])
        XCTAssertEqual(e.map(\.enabled), [true, false, true])
        XCTAssertEqual(e.map(\.restoreName), ["blog", nil, nil])
    }

    // Review Focus 5
    func testUnreadableAndDownloadingAreDisabled() {
        let e = SnapshotMenu.entries([.unreadable("bad"), .downloading("cloud")],
                                     running: [], timeZone: tz)
        XCTAssertEqual(e.map(\.title), ["bad (unreadable)", "cloud (downloading from iCloud…)"])
        XCTAssertEqual(e.map(\.enabled), [false, false])
    }

    func testEmpty() {
        XCTAssertEqual(SnapshotMenu.entries([], running: [], timeZone: tz),
                       [SnapshotMenuEntry(title: "No saved sessions", restoreName: nil, enabled: false)])
    }

    func testRestoreAllDisabledWhenNothingRestorable() {
        let e = SnapshotMenu.entries([.ready(file("work", windows: 1, claudes: 1))],
                                     running: ["work"], timeZone: tz)
        XCTAssertEqual(e.last, SnapshotMenuEntry(title: "Restore All", restoreName: nil, enabled: false))
    }

    func testRestorableNames() {
        XCTAssertEqual(SnapshotMenu.restorableNames([.ready(file("b", windows: 1, claudes: 0)),
                                                     .ready(file("a", windows: 1, claudes: 0)),
                                                     .unreadable("x")],
                                                    running: ["b"]), ["a"])
    }

    func testBadTimestampStillRenders() {
        var f = file("work", windows: 1, claudes: 0)
        f.savedAt = "yesterday"
        XCTAssertEqual(SnapshotMenu.summary(f, timeZone: tz), "work — 1 window, 0 claude · saved yesterday")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SnapshotMenuTests`
Expected: FAIL — "cannot find 'SnapshotMenu' in scope".

- [ ] **Step 3: Implement `Sources/ClaudeLightsCore/SnapshotMenu.swift`**

```swift
import Foundation

/// One file in the snapshot folder, as the store found it.
public enum SnapshotListing: Equatable, Sendable {
    case ready(SnapshotFile)
    /// An iCloud placeholder whose download was just requested.
    case downloading(String)
    case unreadable(String)

    public var name: String {
        switch self {
        case .ready(let f): return f.session.name
        case .downloading(let n), .unreadable(let n): return n
        }
    }
}

public struct SnapshotMenuEntry: Equatable, Sendable {
    public let title: String
    /// Snapshot to restore when clicked; nil for "Restore All" and disabled rows.
    public let restoreName: String?
    public let enabled: Bool

    public init(title: String, restoreName: String?, enabled: Bool) {
        self.title = title; self.restoreName = restoreName; self.enabled = enabled
    }
}

public enum SnapshotMenu {
    public static let restoreAllTitle = "Restore All"

    public static func summary(_ file: SnapshotFile, timeZone: TimeZone = .current) -> String {
        let windows = file.session.windows.count
        let claudes = file.session.windows.flatMap(\.panes).filter { $0.claude != nil }.count
        return "\(file.session.name) — \(windows) window\(windows == 1 ? "" : "s"), "
            + "\(claudes) claude · saved \(shortDate(file.savedAt, timeZone: timeZone))"
    }

    public static func restorableNames(_ listings: [SnapshotListing], running: Set<String>) -> [String] {
        listings.compactMap { l -> String? in
            if case .ready(let f) = l, !running.contains(f.session.name) { return f.session.name }
            return nil
        }.sorted()
    }

    public static func entries(_ listings: [SnapshotListing], running: Set<String>,
                               timeZone: TimeZone = .current) -> [SnapshotMenuEntry] {
        guard !listings.isEmpty else {
            return [SnapshotMenuEntry(title: "No saved sessions", restoreName: nil, enabled: false)]
        }
        var out = listings.sorted { $0.name < $1.name }.map { l -> SnapshotMenuEntry in
            switch l {
            case .ready(let f):
                let isRunning = running.contains(f.session.name)
                return SnapshotMenuEntry(
                    title: summary(f, timeZone: timeZone) + (isRunning ? " (running)" : ""),
                    restoreName: isRunning ? nil : f.session.name, enabled: !isRunning)
            case .downloading(let n):
                return SnapshotMenuEntry(title: "\(n) (downloading from iCloud…)",
                                         restoreName: nil, enabled: false)
            case .unreadable(let n):
                return SnapshotMenuEntry(title: "\(n) (unreadable)", restoreName: nil, enabled: false)
            }
        }
        if listings.contains(where: { if case .ready = $0 { return true }; return false }) {
            out.append(SnapshotMenuEntry(
                title: restoreAllTitle, restoreName: nil,
                enabled: !restorableNames(listings, running: running).isEmpty))
        }
        return out
    }

    /// "2026-10-14T09:00:00-07:00" → "10-14 09:00"; unparseable text is shown as-is.
    static func shortDate(_ iso: String, timeZone: TimeZone) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SnapshotMenuTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeLightsCore/SnapshotMenu.swift Tests/ClaudeLightsCoreTests/SnapshotMenuTests.swift
git commit -m "feat: build the Restore submenu entries for saved sessions"
```

---

### Task 6: iCloud snapshot store + tmux error capture

Shell layer, not unit-tested (project rule); verified in Task 8.

**Files:**
- Create: `Sources/ClaudeLights/SnapshotStore.swift`
- Modify: `Sources/ClaudeLights/Shell.swift` (add `runResult`)
- Modify: `Sources/ClaudeLights/Tmux.swift` (add `runResult`)

**Interfaces:**
- Consumes: `SnapshotCodec`, `SnapshotFile`, `SnapshotListing` (Tasks 1, 5).
- Produces:
  - `struct ShellResult { let status: Int32; let stdout: String; let stderr: String }`, `Shell.runResult(_ executable: String, _ arguments: [String]) -> ShellResult?` (nil only when the process cannot launch).
  - `Tmux.runResult(_ args: [String]) -> ShellResult?`
  - `enum SnapshotStoreError: LocalizedError { case iCloudUnavailable }`
  - `final class SnapshotStore { init(cloudDocs: URL = SnapshotStore.defaultCloudDocs, computerName: String = SnapshotStore.currentComputerName()); var folder: URL; func list() throws -> [SnapshotListing]; func write(_ file: SnapshotFile) throws; func read(name: String) throws -> SnapshotFile }`

- [ ] **Step 1: Add `Shell.runResult` to `Sources/ClaudeLights/Shell.swift`** (inside `enum Shell`, after `run`)

```swift
    /// Runs a subprocess and returns its exit status, stdout and stderr;
    /// nil only when it cannot be launched.
    static func runResult(_ executable: String, _ arguments: [String]) -> ShellResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ShellResult(status: process.terminationStatus,
                           stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self))
    }
```

and at file top level:

```swift
struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
}
```

- [ ] **Step 2: Add `Tmux.runResult` to `Sources/ClaudeLights/Tmux.swift`** (after `run`)

```swift
    /// Like `run`, but keeps the exit status and stderr for error reporting.
    static func runResult(_ args: [String]) -> ShellResult? {
        guard let path else { return nil }
        return Shell.runResult(path, socketArgs() + args)
    }
```

- [ ] **Step 3: Create `Sources/ClaudeLights/SnapshotStore.swift`**

```swift
import Foundation
import SystemConfiguration
import ClaudeLightsCore

enum SnapshotStoreError: LocalizedError {
    case iCloudUnavailable
    var errorDescription: String? { "iCloud Drive is not available" }
}

/// Snapshot files in iCloud Drive, one folder per Mac. No local fallback:
/// without iCloud Drive every call throws `iCloudUnavailable`.
final class SnapshotStore {
    static let defaultCloudDocs = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")

    static func currentComputerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?)
            ?? ProcessInfo.processInfo.hostName
    }

    private let cloudDocs: URL
    let folder: URL

    init(cloudDocs: URL = SnapshotStore.defaultCloudDocs,
         computerName: String = SnapshotStore.currentComputerName()) {
        self.cloudDocs = cloudDocs
        folder = cloudDocs.appendingPathComponent("ClaudeLights/sessions", isDirectory: true)
            .appendingPathComponent(SnapshotCodec.folderName(computerName: computerName),
                                    isDirectory: true)
    }

    private func ensureFolder() throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cloudDocs.path, isDirectory: &isDir),
              isDir.boolValue else { throw SnapshotStoreError.iCloudUnavailable }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Every snapshot in this Mac's folder. Evicted iCloud placeholders
    /// (`.<file>.icloud`) get a download request and show as downloading.
    func list() throws -> [SnapshotListing] {
        try ensureFolder()
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        var out: [SnapshotListing] = []
        for file in files {
            if let name = SnapshotCodec.sessionName(fromFileName: file) {
                do { out.append(.ready(try read(name: name))) } catch { out.append(.unreadable(name)) }
            } else if file.hasPrefix("."), file.hasSuffix(".json.icloud"),
                      let name = SnapshotCodec.sessionName(
                        fromFileName: String(file.dropFirst().dropLast(".icloud".count))) {
                let real = folder.appendingPathComponent(SnapshotCodec.fileName(for: name))
                try? FileManager.default.startDownloadingUbiquitousItem(at: real)
                out.append(.downloading(name))
            }
        }
        return out
    }

    func read(name: String) throws -> SnapshotFile {
        let url = folder.appendingPathComponent(SnapshotCodec.fileName(for: name))
        var data: Data?
        var coordError: NSError?
        var readError: Error?
        // Coordinated read: waits for iCloud to finish writing the file.
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            do { data = try Data(contentsOf: u) } catch { readError = error }
        }
        if let coordError { throw coordError }
        if let readError { throw readError }
        return try SnapshotCodec.decode(data ?? Data())
    }

    /// Atomic replace of `<name>.json`.
    func write(_ file: SnapshotFile) throws {
        try ensureFolder()
        let url = folder.appendingPathComponent(SnapshotCodec.fileName(for: file.session.name))
        let data = try SnapshotCodec.encode(file)
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &coordError) { u in
            do { try data.write(to: u, options: .atomic) } catch { writeError = error }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!` with no errors. If `SCDynamicStoreCopyComputerName`'s return type needs bridging, use `SCDynamicStoreCopyComputerName(nil, nil).map { $0 as String }`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeLights/Shell.swift Sources/ClaudeLights/Tmux.swift Sources/ClaudeLights/SnapshotStore.swift
git commit -m "feat: store session snapshots in iCloud Drive, one folder per Mac"
```

---

### Task 7: Snapshot service (save / restore) + terminal window opener

**Files:**
- Create: `Sources/ClaudeLights/SnapshotService.swift`
- Modify: `Sources/ClaudeLights/Jumper.swift:142-174` (extract `openTerminalWindow(attachingTo:)`)
- Modify: `Sources/ClaudeLights/Notifier.swift` (add `notifyInfo`)

**Interfaces:**
- Consumes: `SnapshotStore`, `Tmux.runResult`, `Shell.run` (Task 6); `SnapshotTmux`, `SnapshotBuilder`, `ProcessTable`, `RestorePlan`, `SnapshotMenu` (Tasks 2–5).
- Produces:
  - `Jumper.openTerminalWindow(attachingTo session: String)` (internal, no alert).
  - `Notifier.notifyInfo(title: String, body: String)`
  - `final class SnapshotService { init(store: SnapshotStore, jumper: Jumper); func runningSessionNames() -> Set<String>; func listings() -> Result<[SnapshotListing], Error>; func saveAll(sessions: [Session]) -> String; func restore(names: [String]) -> String }` — the `String` returns are the notification bodies.

- [ ] **Step 1: Extract the window opener in `Jumper.swift`**

Replace the body of `offerToOpenWindow(attachingTo:)` after `guard alert.runModal() == .alertFirstButtonReturn else { return }` so it ends with a call, and add the new method:

```swift
    /// No tmux client anywhere (all terminal windows closed). Ask, then open
    /// a fresh terminal window attached to the target session.
    private func offerToOpenWindow(attachingTo session: String) {
        guard Tmux.path != nil, preferredTerminalBundleId() != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "No terminal window is attached to tmux"
        alert.informativeText =
            "Open a new terminal window attached to “\(session)”?"
        alert.addButton(withTitle: "Open Window")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openTerminalWindow(attachingTo: session)
    }

    /// Opens a new iTerm2 / Apple Terminal window running `tmux attach`.
    func openTerminalWindow(attachingTo session: String) {
        guard let tmuxPath = Tmux.path, let bundleId = preferredTerminalBundleId() else { return }
        let attach = TmuxMapper.attachCommand(tmuxPath: tmuxPath, session: session)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        if bundleId == "com.googlecode.iterm2" {
            script = """
            tell application "iTerm2"
                activate
                create window with default profile command "\(attach)"
            end tell
            """
        } else {
            script = """
            tell application "Terminal"
                activate
                do script "\(attach)"
            end tell
            """
        }
        Shell.run("/usr/bin/osascript", ["-e", script])
    }
```

- [ ] **Step 2: Add `notifyInfo` to `Notifier.swift`** (after `notifyUpdate`)

```swift
    /// Plain informational banner (save/restore results); not clickable.
    func notifyInfo(title: String, body: String) {
        guard hasBundle, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "info-\(UUID().uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
```

- [ ] **Step 3: Create `Sources/ClaudeLights/SnapshotService.swift`**

```swift
import Foundation
import ClaudeLightsCore

/// Captures and rebuilds sessions. Blocking (runs tmux/ps): call off the main thread.
final class SnapshotService {
    private let store: SnapshotStore
    private let jumper: Jumper

    init(store: SnapshotStore, jumper: Jumper) {
        self.store = store
        self.jumper = jumper
    }

    func runningSessionNames() -> Set<String> {
        let out = Tmux.run(["list-sessions", "-F", "#{session_name}"]) ?? ""
        return Set(out.split(separator: "\n").map(String.init))
    }

    func listings() -> Result<[SnapshotListing], Error> {
        Result { try store.list() }
    }

    private func baseIndex() -> Int {
        Int(Tmux.run(["show-options", "-gv", "base-index"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    /// Writes one file per running tmux session plus the loose snapshot.
    /// Files of sessions not running now are left untouched.
    func saveAll(sessions: [Session]) -> String {
        let tmuxOut = Tmux.run(["list-sessions", "-F", SnapshotTmux.sessionsFormat])
        let tmuxRunning = tmuxOut != nil
        let snaps = SnapshotBuilder.all(
            tmuxSessions: SnapshotTmux.parseSessions(tmuxOut ?? ""),
            windows: SnapshotTmux.parseWindows(
                Tmux.run(["list-windows", "-a", "-F", SnapshotTmux.windowsFormat]) ?? ""),
            panes: SnapshotTmux.parsePanes(
                Tmux.run(["list-panes", "-a", "-F", SnapshotTmux.panesFormat]) ?? ""),
            sessions: sessions,
            procs: ProcessTable.parse(Shell.run("/bin/ps", ProcessTable.psArguments) ?? ""),
            home: NSHomeDirectory(),
            baseIndex: tmuxRunning ? baseIndex() : 0)
        let savedAt = SnapshotCodec.timestamp(Date())
        var tmuxCount = 0, looseCount = 0
        var failures: [String] = []
        for snap in snaps {
            do {
                try store.write(SnapshotFile(savedAt: savedAt, session: snap))
                if snap.name == SnapshotCodec.looseName {
                    looseCount = snap.windows.count
                } else {
                    tmuxCount += 1
                }
            } catch {
                failures.append("\(snap.name): \(error.localizedDescription)")
            }
        }
        var body = "Saved \(tmuxCount) tmux session\(tmuxCount == 1 ? "" : "s")"
            + " + \(looseCount) loose session\(looseCount == 1 ? "" : "s")"
        if !tmuxRunning { body += " (tmux not running, skipped)" }
        if !failures.isEmpty { body += "\nFailed: " + failures.joined(separator: "; ") }
        return body
    }

    /// Rebuilds each named snapshot that is not already running, opening one
    /// terminal window per restored session.
    func restore(names: [String]) -> String {
        guard Tmux.available else { return "tmux is not installed" }
        var restored: [String] = []
        var problems: [String] = []
        for name in names {
            if runningSessionNames().contains(name) {
                problems.append("\(name): already running")
                continue
            }
            do {
                let snap = try store.read(name: name).session
                guard !snap.windows.isEmpty else {
                    problems.append("\(name): snapshot has no windows")
                    continue
                }
                if let error = run(RestorePlan.newSession(snap)) {
                    problems.append("\(name): \(error)")
                    continue
                }
                let cmds = RestorePlan.commands(snap, baseIndex: baseIndex())
                if let error = cmds.lazy.compactMap({ self.run($0) }).first {
                    problems.append("\(name): \(error)")
                }
                // Open the window even after a partial failure, so the user sees what was built.
                jumper.openTerminalWindow(attachingTo: name)
                restored.append(name)
            } catch {
                problems.append("\(name): \(error.localizedDescription)")
            }
        }
        var body = restored.isEmpty ? "Nothing restored" : "Restored " + restored.joined(separator: ", ")
        if !problems.isEmpty { body += "\n" + problems.joined(separator: "\n") }
        return body
    }

    /// nil on success, else tmux's error text.
    private func run(_ args: [String]) -> String? {
        guard let r = Tmux.runResult(args) else { return "could not launch tmux" }
        guard r.status != 0 else { return nil }
        let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "tmux \(args.first ?? ""): \(msg.isEmpty ? "exit \(r.status)" : msg)"
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeLights/SnapshotService.swift Sources/ClaudeLights/Jumper.swift Sources/ClaudeLights/Notifier.swift
git commit -m "feat: save and restore session snapshots through tmux"
```

---

### Task 8: Menu items, wiring, docs, manual verification

**Files:**
- Modify: `Sources/ClaudeLights/StatusItemController.swift` (callbacks + items before `Show Light Bar`)
- Modify: `Sources/ClaudeLights/AppDelegate.swift` (create service, wire callbacks)
- Modify: `CLAUDE.md` (Hard-won facts bullet)
- Modify: `docs/superpowers/specs/2026-10-14-session-snapshots-design.md` only if behavior had to differ.

**Interfaces:**
- Consumes: `SnapshotService` (Task 7), `SnapshotMenu`, `SnapshotMenuEntry` (Task 5).
- Produces: `StatusItemController.onSaveSessions: (() -> Void)?`, `onRestore: (([String]) -> Void)?`, `snapshotMenuEntries: () -> [SnapshotMenuEntry]`, `restorableNames: () -> [String]`.

- [ ] **Step 1: Add callbacks to `StatusItemController`** (next to `onCheckForUpdates`)

```swift
    var onSaveSessions: (() -> Void)?
    /// Snapshot names to restore (one for an item, all restorable for "Restore All").
    var onRestore: (([String]) -> Void)?
    var snapshotMenuEntries: () -> [SnapshotMenuEntry] = { [] }
    var restorableNames: () -> [String] = { [] }
```

- [ ] **Step 2: Insert the items in `populate`**, directly before `let toggle = NSMenuItem(title: "Show Light Bar", …)`

```swift
        let save = NSMenuItem(title: "Save Sessions", action: #selector(saveSessions), keyEquivalent: "")
        save.target = self
        save.image = Self.spacerImage
        menu.addItem(save)

        let restore = NSMenuItem(title: "Restore", action: nil, keyEquivalent: "")
        restore.image = Self.spacerImage
        let sub = NSMenu()
        for entry in snapshotMenuEntries() {
            if entry.title == SnapshotMenu.restoreAllTitle { sub.addItem(.separator()) }
            let mi = NSMenuItem(title: entry.title,
                                action: entry.enabled ? #selector(restoreItem(_:)) : nil,
                                keyEquivalent: "")
            mi.target = entry.enabled ? self : nil
            mi.isEnabled = entry.enabled
            mi.representedObject = entry.restoreName // nil → Restore All
            sub.addItem(mi)
        }
        restore.submenu = sub
        menu.addItem(restore)
        menu.addItem(.separator())
```

and the actions next to `checkForUpdates`:

```swift
    @objc private func saveSessions() { onSaveSessions?() }

    @objc private func restoreItem(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String {
            onRestore?([name])
        } else {
            onRestore?(restorableNames())
        }
    }
```

Note: the menu has `autoenablesItems` on by default; disabled rows have no action/target, so AppKit keeps them grey.

- [ ] **Step 3: Wire in `AppDelegate.applicationDidFinishLaunching`** (after the updater wiring). Add the property `private lazy var snapshots = SnapshotService(store: SnapshotStore(), jumper: jumper)` next to `jumper`, then:

```swift
        statusController.snapshotMenuEntries = { [weak self] in
            guard let self else { return [] }
            switch self.snapshots.listings() {
            case .success(let listings):
                return SnapshotMenu.entries(listings, running: self.snapshots.runningSessionNames())
            case .failure(let error):
                return [SnapshotMenuEntry(title: error.localizedDescription, restoreName: nil,
                                          enabled: false)]
            }
        }
        statusController.restorableNames = { [weak self] in
            guard let self, case .success(let listings) = self.snapshots.listings() else { return [] }
            return SnapshotMenu.restorableNames(listings, running: self.snapshots.runningSessionNames())
        }
        statusController.onSaveSessions = { [weak self] in
            guard let self else { return }
            let sessions = self.store.sessions
            DispatchQueue.global(qos: .userInitiated).async {
                let body: String
                do {
                    _ = try self.snapshots.listings().get() // surfaces iCloudUnavailable
                    body = self.snapshots.saveAll(sessions: sessions)
                } catch {
                    body = error.localizedDescription
                }
                DispatchQueue.main.async { self.notifier.notifyInfo(title: "Save Sessions", body: body) }
            }
        }
        statusController.onRestore = { [weak self] names in
            guard let self, !names.isEmpty else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let body = self.snapshots.restore(names: names)
                DispatchQueue.main.async { self.notifier.notifyInfo(title: "Restore", body: body) }
            }
        }
```

- [ ] **Step 4: Build, test, bundle**

Run: `swift test && scripts/bundle.sh && open build/ClaudeLights.app`
Expected: tests PASS; app relaunches; menu shows `Save Sessions` and `Restore ▸` above `Show Light Bar`. If macOS asks for iCloud Drive access, allow it.

- [ ] **Step 5: Manual verification** (record what you saw in the commit message body)

1. Have a tmux session `snaptest` with 2 panes (one running `claude`, one running `tail -f /dev/null`), and one `claude` in a plain iTerm2/Terminal tab started in a directory with a space, e.g. `mkdir -p "/tmp/snap test" && cd "/tmp/snap test" && claude`.
2. Click `Save Sessions`. Expected notification: `Saved N tmux sessions + 1 loose session`.
3. Run `ls ~/Library/Mobile\ Documents/com~apple~CloudDocs/ClaudeLights/sessions/*/` — expect `snaptest.json` and `claude-loose-sessions.json`; `cat` the loose file and confirm `"cwd" : "/tmp/snap test"`.
4. Open `Restore ▸`: `snaptest … (running)` is greyed.
5. Quit both Claudes, run `tmux kill-session -t snaptest`, close the plain-tab Claude.
6. Click `Restore All`. Expected: two terminal windows open; `snaptest` has 2 panes in the original layout, Claude resumed in pane 0 and `tail -f /dev/null` typed but not run in pane 1; `claude-loose-sessions` has one window that is in `/tmp/snap test` and resumes the conversation.
7. Click `Save Sessions` again with `claude-loose-sessions` running and one new plain-tab Claude; `cat` the loose file — expect both windows.

- [ ] **Step 6: Document in `CLAUDE.md`** — add under "Hard-won facts":

```markdown
- **Save/Restore sessions:** snapshots live in iCloud Drive
  (`ClaudeLights/sessions/<ComputerName>/<name>.json`, old tmux-claude v2
  format), never locally. Non-tmux Claude sessions are saved together as
  `claude-loose-sessions` and restored into a tmux session of that name.
  Save only rewrites files of sessions running now. Single-pane windows are
  targeted by window (not `.0`) so `pane-base-index` doesn't matter.
```

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeLights/StatusItemController.swift Sources/ClaudeLights/AppDelegate.swift CLAUDE.md
git commit -m "feat: Save Sessions / Restore menu for tmux and loose Claude sessions"
```
