# Claude Lights Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu bar app showing live traffic-light status of all local Claude Code sessions, with an always-on-top floating light bar, one-click jump to the session's tmux window, and notification + sound when a session starts waiting for the user.

**Architecture:** SwiftPM package with two targets: `ClaudeLightsCore` (pure, fully unit-tested logic: parsing, state mapping, tmux joining, transcript extraction, transition detection) and `ClaudeLights` (AppKit/SwiftUI shell: poller, tray, floating panel, jumper, notifier). The poller reads the session registry files at `~/.claude/sessions/<pid>.json` directly (same data `claude agents --json` serves, verified identical on this machine) with a `kill(pid, 0)` liveness check — this avoids spawning the heavy `claude` CLI every 2 seconds. Spec is amended accordingly in Task 1.

**Tech Stack:** Swift 5.9+ toolchain (6.3.1 installed), AppKit + SwiftUI (NSPanel/NSStatusItem/NSHostingView), UserNotifications, ServiceManagement (launch at login), XCTest.

## Global Constraints

- Platform floor: macOS 13 (`platforms: [.macOS(.v13)]`, `LSMinimumSystemVersion` 13.0).
- No third-party dependencies. No Xcode project — SwiftPM + a bundle script.
- All code, comments, docs, commit messages in English.
- Repo root: `/Users/dev/claude-lights`. All paths below are relative to it.
- Traffic-light semantics: red = waiting for user, yellow = busy/working, green = idle/done, gray = unknown. Red always sorts first.
- Only `kind == "interactive"` sessions are shown.
- Unknown/malformed data must map to gray, never crash.
- Notify (banner + sound) only on transition *into* red; never on the first poll snapshot.
- Display label = basename of `cwd` (the pretty `/status` title is not persisted on disk and is unavailable).

---

### Task 1: SwiftPM scaffold + spec amendment

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/ClaudeLightsCore/Models.swift`, `Sources/ClaudeLights/main.swift` (placeholder), `Tests/ClaudeLightsCoreTests/StateMapperTests.swift` (placeholder)
- Modify: `docs/superpowers/specs/2026-07-07-claude-lights-design.md` (data source wording)

**Interfaces:**
- Produces: package layout every later task lives in; `LightState` enum consumed everywhere.

- [ ] **Step 1: Write Package.swift and .gitignore**

`Package.swift`:
```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeLights",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ClaudeLightsCore"),
        .executableTarget(name: "ClaudeLights", dependencies: ["ClaudeLightsCore"]),
        .testTarget(name: "ClaudeLightsCoreTests", dependencies: ["ClaudeLightsCore"]),
    ]
)
```

`.gitignore`:
```
.build/
build/
.DS_Store
```

- [ ] **Step 2: Create minimal compiling sources**

`Sources/ClaudeLightsCore/Models.swift`:
```swift
import Foundation

/// Traffic-light state of a session. Lower sortRank = more urgent.
public enum LightState: String, Comparable, Sendable {
    case red, yellow, green, gray

    public var sortRank: Int {
        switch self {
        case .red: return 0
        case .yellow: return 1
        case .green: return 2
        case .gray: return 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.sortRank < rhs.sortRank }
}
```

`Sources/ClaudeLights/main.swift`:
```swift
import ClaudeLightsCore

print("ClaudeLights placeholder — replaced in Task 8")
```

`Tests/ClaudeLightsCoreTests/StateMapperTests.swift`:
```swift
import XCTest
@testable import ClaudeLightsCore

final class StateMapperTests: XCTestCase {
    func testLightStateOrdering() {
        XCTAssertLessThan(LightState.red, LightState.yellow)
        XCTAssertLessThan(LightState.yellow, LightState.green)
        XCTAssertLessThan(LightState.green, LightState.gray)
    }
}
```

- [ ] **Step 3: Verify build and tests pass**

Run: `cd /Users/dev/claude-lights && swift test`
Expected: PASS (1 test).

- [ ] **Step 4: Amend spec data-source wording**

In `docs/superpowers/specs/2026-07-07-claude-lights-design.md`, change the sentence
"The app may read those files directly as a fallback, but the CLI is the stable contract."
to:
"The app reads those registry files directly (with a `kill(pid, 0)` liveness check to skip stale files) — spawning the `claude` CLI every 2 s is too heavy. The CLI remains the reference for the schema."

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "chore: scaffold SwiftPM package with core/app/test targets"
```

---

### Task 2: State mapping (status/state → light)

**Files:**
- Create: `Sources/ClaudeLightsCore/StateMapper.swift`
- Modify: `Tests/ClaudeLightsCoreTests/StateMapperTests.swift`

**Interfaces:**
- Produces: `StateMapper.light(status: String?, state: String?) -> LightState`

- [ ] **Step 1: Write failing tests**

Append to `Tests/ClaudeLightsCoreTests/StateMapperTests.swift` inside the class:
```swift
    func testBusyIsYellow() {
        XCTAssertEqual(StateMapper.light(status: "busy", state: nil), .yellow)
    }

    func testIdleIsGreen() {
        XCTAssertEqual(StateMapper.light(status: "idle", state: nil), .green)
    }

    func testIdleWithDoneStateIsGreen() {
        XCTAssertEqual(StateMapper.light(status: "idle", state: "done"), .green)
    }

    func testWaitingVariantsAreRed() {
        // Exact waiting value unverified at design time; match defensively.
        XCTAssertEqual(StateMapper.light(status: "waiting", state: nil), .red)
        XCTAssertEqual(StateMapper.light(status: "waiting_input", state: nil), .red)
        XCTAssertEqual(StateMapper.light(status: "needs_permission", state: nil), .red)
        XCTAssertEqual(StateMapper.light(status: "blocked", state: nil), .red)
        XCTAssertEqual(StateMapper.light(status: "needs_attention", state: nil), .red)
    }

    func testUnknownIsGray() {
        XCTAssertEqual(StateMapper.light(status: nil, state: nil), .gray)
        XCTAssertEqual(StateMapper.light(status: "banana", state: nil), .gray)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test 2>&1 | tail -5`
Expected: compile error "cannot find 'StateMapper'".

- [ ] **Step 3: Implement**

`Sources/ClaudeLightsCore/StateMapper.swift`:
```swift
import Foundation

public enum StateMapper {
    /// Maps registry status/state fields to a traffic light.
    /// Verified values on 2.1.207: status "busy"/"idle", state "done".
    /// Waiting-state value is matched by substring until verified live (Task 13).
    public static func light(status: String?, state: String?) -> LightState {
        let s = (status ?? "").lowercased()
        let redMarkers = ["wait", "input", "permission", "attention", "block"]
        if redMarkers.contains(where: { s.contains($0) }) { return .red }
        if s == "busy" || s == "working" || s == "running" { return .yellow }
        if s == "idle" || (state ?? "").lowercased() == "done" { return .green }
        return .gray
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test 2>&1 | tail -3`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: map session status to traffic-light state"
```

---

### Task 3: Agent record parsing (registry files + agents JSON)

**Files:**
- Create: `Sources/ClaudeLightsCore/AgentRecord.swift`, `Tests/ClaudeLightsCoreTests/AgentRecordTests.swift`

**Interfaces:**
- Produces:
  - `struct AgentRecord` (all fields optional): `pid: Int?`, `cwd: String?`, `kind: String?`, `sessionId: String?`, `name: String?`, `status: String?`, `state: String?`, `startedAt: Double?`, `statusUpdatedAt: Double?` — with a public memberwise init defaulting all to nil.
  - `AgentRecord.parseList(_ json: String) -> [AgentRecord]` (array JSON from `claude agents --json`)
  - `AgentRecord.parseOne(_ json: String) -> AgentRecord?` (single registry file)
  - `SessionRegistry.load(dir: URL, isAlive: (Int) -> Bool) -> [AgentRecord]`

- [ ] **Step 1: Write failing tests**

`Tests/ClaudeLightsCoreTests/AgentRecordTests.swift`:
```swift
import XCTest
@testable import ClaudeLightsCore

final class AgentRecordTests: XCTestCase {
    // Real registry file content captured from ~/.claude/sessions/783.json (2.1.207)
    let registryFixture = """
    {"pid":783,"sessionId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cwd":"/Users/dev","startedAt":1783747666861,"procStart":"Sat Jul 11 05:27:46 2026","version":"2.1.207","peerProtocol":1,"kind":"interactive","entrypoint":"cli","name":"dev-0b","nameSource":"derived","status":"busy","updatedAt":1783872850584,"statusUpdatedAt":1783872850584}
    """

    // Real `claude agents --json` output shape
    let listFixture = """
    [
      {"pid":9895,"id":"f1cea4f1","cwd":"/Users/dev/webapp","kind":"background","startedAt":1783717765103,"sessionId":"e93ce2d9","name":"bg task","status":"idle","state":"done"},
      {"pid":783,"cwd":"/Users/dev","kind":"interactive","startedAt":1783747666861,"sessionId":"de78fb42","name":"dev-0b","status":"busy"}
    ]
    """

    func testParseRegistryFile() {
        let r = AgentRecord.parseOne(registryFixture)
        XCTAssertEqual(r?.pid, 783)
        XCTAssertEqual(r?.kind, "interactive")
        XCTAssertEqual(r?.status, "busy")
        XCTAssertEqual(r?.statusUpdatedAt, 1783872850584)
        XCTAssertEqual(r?.cwd, "/Users/dev")
    }

    func testParseList() {
        let rs = AgentRecord.parseList(listFixture)
        XCTAssertEqual(rs.count, 2)
        XCTAssertEqual(rs[0].kind, "background")
        XCTAssertEqual(rs[1].sessionId, "de78fb42")
    }

    func testMalformedReturnsEmpty() {
        XCTAssertNil(AgentRecord.parseOne("not json"))
        XCTAssertEqual(AgentRecord.parseList("nope").count, 0)
    }

    func testRegistryLoadSkipsDeadPidsAndBadFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cl-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try registryFixture.write(to: dir.appendingPathComponent("783.json"), atomically: true, encoding: .utf8)
        try #"{"pid":999,"kind":"interactive","status":"busy","cwd":"/tmp"}"#
            .write(to: dir.appendingPathComponent("999.json"), atomically: true, encoding: .utf8)
        try "garbage".write(to: dir.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)

        let live = SessionRegistry.load(dir: dir, isAlive: { $0 == 783 })
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].pid, 783)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test 2>&1 | tail -5`
Expected: compile error "cannot find 'AgentRecord'".

- [ ] **Step 3: Implement**

`Sources/ClaudeLightsCore/AgentRecord.swift`:
```swift
import Foundation

/// One Claude Code session as reported by ~/.claude/sessions/<pid>.json
/// (same schema `claude agents --json` serves). All fields optional so a
/// schema drift never crashes us — missing data degrades to gray.
public struct AgentRecord: Decodable, Equatable, Sendable {
    public var pid: Int?
    public var cwd: String?
    public var kind: String?
    public var sessionId: String?
    public var name: String?
    public var status: String?
    public var state: String?
    public var startedAt: Double?
    public var statusUpdatedAt: Double?

    public init(pid: Int? = nil, cwd: String? = nil, kind: String? = nil,
                sessionId: String? = nil, name: String? = nil, status: String? = nil,
                state: String? = nil, startedAt: Double? = nil, statusUpdatedAt: Double? = nil) {
        self.pid = pid; self.cwd = cwd; self.kind = kind
        self.sessionId = sessionId; self.name = name; self.status = status
        self.state = state; self.startedAt = startedAt; self.statusUpdatedAt = statusUpdatedAt
    }

    public static func parseOne(_ json: String) -> AgentRecord? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentRecord.self, from: data)
    }

    public static func parseList(_ json: String) -> [AgentRecord] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([AgentRecord].self, from: data)) ?? []
    }
}

public enum SessionRegistry {
    public static var defaultDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")
    }

    /// Loads all live session records. Stale files of dead processes are skipped.
    public static func load(dir: URL = defaultDir,
                            isAlive: (Int) -> Bool = { kill(pid_t($0), 0) == 0 }) -> [AgentRecord] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> AgentRecord? in
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let record = AgentRecord.parseOne(text),
                      let pid = record.pid, isAlive(pid) else { return nil }
                return record
            }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test 2>&1 | tail -3`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: parse agent records from session registry and agents JSON"
```

---

### Task 4: tmux mapping (pid → tty → pane)

**Files:**
- Create: `Sources/ClaudeLightsCore/TmuxMapper.swift`, `Tests/ClaudeLightsCoreTests/TmuxMapperTests.swift`

**Interfaces:**
- Produces:
  - `struct TmuxPane { tty: String; sessionName: String; windowIndex: String; paneId: String }` (public memberwise init)
  - `TmuxMapper.parsePanes(_ output: String) -> [TmuxPane]` — parses tab-separated `tmux list-panes -a -F '#{pane_tty}\t#{session_name}\t#{window_index}\t#{pane_id}'`
  - `TmuxMapper.parsePidTtys(_ output: String) -> [Int: String]` — parses `ps -o pid=,tty=` output; values prefixed `/dev/`; `??` (no tty) skipped
  - `TmuxMapper.target(forPid: Int, pidTtys: [Int: String], panes: [TmuxPane]) -> TmuxPane?`

- [ ] **Step 1: Write failing tests**

`Tests/ClaudeLightsCoreTests/TmuxMapperTests.swift`:
```swift
import XCTest
@testable import ClaudeLightsCore

final class TmuxMapperTests: XCTestCase {
    let panesFixture = "/dev/ttys001\tmain\t0\t%0\n/dev/ttys004\tmain\t1\t%1\n/dev/ttys007\twork session\t2\t%5\n"
    let psFixture = "  783 ttys001\n 9895 ??\n12345 ttys007\n"

    func testParsePanes() {
        let panes = TmuxMapper.parsePanes(panesFixture)
        XCTAssertEqual(panes.count, 3)
        XCTAssertEqual(panes[0], TmuxPane(tty: "/dev/ttys001", sessionName: "main", windowIndex: "0", paneId: "%0"))
        XCTAssertEqual(panes[2].sessionName, "work session")
    }

    func testParsePidTtysSkipsNoTty() {
        let map = TmuxMapper.parsePidTtys(psFixture)
        XCTAssertEqual(map, [783: "/dev/ttys001", 12345: "/dev/ttys007"])
    }

    func testTargetJoin() {
        let panes = TmuxMapper.parsePanes(panesFixture)
        let map = TmuxMapper.parsePidTtys(psFixture)
        let t = TmuxMapper.target(forPid: 783, pidTtys: map, panes: panes)
        XCTAssertEqual(t?.sessionName, "main")
        XCTAssertEqual(t?.windowIndex, "0")
        XCTAssertNil(TmuxMapper.target(forPid: 9895, pidTtys: map, panes: panes))
        XCTAssertNil(TmuxMapper.target(forPid: 1, pidTtys: map, panes: panes))
    }

    func testEmptyInputs() {
        XCTAssertEqual(TmuxMapper.parsePanes("").count, 0)
        XCTAssertEqual(TmuxMapper.parsePidTtys("").count, 0)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test 2>&1 | tail -5`
Expected: compile error "cannot find 'TmuxMapper'".

- [ ] **Step 3: Implement**

`Sources/ClaudeLightsCore/TmuxMapper.swift`:
```swift
import Foundation

public struct TmuxPane: Equatable, Sendable {
    public let tty: String
    public let sessionName: String
    public let windowIndex: String
    public let paneId: String

    public init(tty: String, sessionName: String, windowIndex: String, paneId: String) {
        self.tty = tty; self.sessionName = sessionName
        self.windowIndex = windowIndex; self.paneId = paneId
    }
}

public enum TmuxMapper {
    /// Format string used with `tmux list-panes -a -F`.
    public static let panesFormat = "#{pane_tty}\t#{session_name}\t#{window_index}\t#{pane_id}"

    public static func parsePanes(_ output: String) -> [TmuxPane] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else { return nil }
            return TmuxPane(tty: parts[0], sessionName: parts[1], windowIndex: parts[2], paneId: parts[3])
        }
    }

    /// Parses `ps -o pid=,tty= -p <pids>`; ttys come back as e.g. "ttys001".
    public static func parsePidTtys(_ output: String) -> [Int: String] {
        var map: [Int: String] = [:]
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2, let pid = Int(cols[0]), cols[1] != "??" else { continue }
            map[pid] = "/dev/" + cols[1]
        }
        return map
    }

    public static func target(forPid pid: Int, pidTtys: [Int: String], panes: [TmuxPane]) -> TmuxPane? {
        guard let tty = pidTtys[pid] else { return nil }
        return panes.first { $0.tty == tty }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test 2>&1 | tail -3`
Expected: PASS, 14 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: join session pids to tmux panes via tty"
```

---

### Task 5: Transcript tail extraction (waiting description)

**Files:**
- Create: `Sources/ClaudeLightsCore/TranscriptReader.swift`, `Tests/ClaudeLightsCoreTests/TranscriptReaderTests.swift`

**Interfaces:**
- Produces:
  - `TranscriptReader.transcriptURL(cwd: String, sessionId: String, home: String) -> URL` — `~/.claude/projects/<slug>/<sessionId>.jsonl`, slug = cwd with `/` and `.` replaced by `-`
  - `TranscriptReader.tailLines(of: URL, maxBytes: Int) -> [String]`
  - `TranscriptReader.waitingDescription(fromJSONLines: [String]) -> String?` — last assistant text (truncated to 100 chars, newlines flattened) or `"Wants to run: <tool names>"`
  - `TranscriptReader.truncate(_ s: String, max: Int) -> String`

- [ ] **Step 1: Write failing tests**

`Tests/ClaudeLightsCoreTests/TranscriptReaderTests.swift`:
```swift
import XCTest
@testable import ClaudeLightsCore

final class TranscriptReaderTests: XCTestCase {
    func testTranscriptURLSlug() {
        let url = TranscriptReader.transcriptURL(cwd: "/Users/dev/my.app", sessionId: "abc", home: "/Users/dev")
        XCTAssertEqual(url.path, "/Users/dev/.claude/projects/-Users-dev-my-app/abc.jsonl")
    }

    func testWaitingDescriptionPrefersLastAssistantText() {
        let lines = [
            #"{"type":"user","message":{"content":"hi"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Old answer"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Shall I delete the branch?"}]}}"#,
            #"{"type":"user","message":{"content":"..."}}"#,
        ]
        XCTAssertEqual(TranscriptReader.waitingDescription(fromJSONLines: lines), "Shall I delete the branch?")
    }

    func testWaitingDescriptionToolUseOnly() {
        let lines = [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#,
        ]
        XCTAssertEqual(TranscriptReader.waitingDescription(fromJSONLines: lines), "Wants to run: Bash")
    }

    func testWaitingDescriptionNoneForGarbage() {
        XCTAssertNil(TranscriptReader.waitingDescription(fromJSONLines: ["nope", "{}"]))
        XCTAssertNil(TranscriptReader.waitingDescription(fromJSONLines: []))
    }

    func testTruncateFlattensAndLimits() {
        let long = String(repeating: "a", count: 150) + "\nnext line"
        let out = TranscriptReader.truncate(long, max: 100)
        XCTAssertEqual(out.count, 101) // 100 chars + ellipsis
        XCTAssertFalse(out.contains("\n"))
        XCTAssertEqual(TranscriptReader.truncate("short\ntext", max: 100), "short text")
    }

    func testTailLinesReadsLastLines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cl-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let content = (1...1000).map { #"{"n":\#($0)}"# }.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
        let lines = TranscriptReader.tailLines(of: url, maxBytes: 1024)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertEqual(lines.last, #"{"n":1000}"#)
        XCTAssertLessThan(lines.count, 1000)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test 2>&1 | tail -5`
Expected: compile error "cannot find 'TranscriptReader'".

- [ ] **Step 3: Implement**

`Sources/ClaudeLightsCore/TranscriptReader.swift`:
```swift
import Foundation

/// Extracts a one-line human description of what a session is doing/waiting for
/// from the tail of its transcript at ~/.claude/projects/<slug>/<sessionId>.jsonl.
public enum TranscriptReader {
    public static func transcriptURL(cwd: String, sessionId: String,
                                     home: String = NSHomeDirectory()) -> URL {
        let slug = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(slug)
            .appendingPathComponent(sessionId + ".jsonl")
    }

    /// Reads at most maxBytes from the end of the file, split into whole lines.
    public static func tailLines(of url: URL, maxBytes: Int = 64 * 1024) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n").map(String.init)
        if offset > 0, !lines.isEmpty { lines.removeFirst() } // drop partial first line
        return lines
    }

    /// Walks lines backwards for the newest assistant entry; returns its last
    /// text block, or the tool names it tried to use.
    public static func waitingDescription(fromJSONLines lines: [String]) -> String? {
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            var toolNames: [String] = []
            var lastText: String?
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String,
                       !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastText = t }
                case "tool_use":
                    if let n = block["name"] as? String { toolNames.append(n) }
                default: break
                }
            }
            if let t = lastText { return truncate(t) }
            if !toolNames.isEmpty { return "Wants to run: " + toolNames.joined(separator: ", ") }
        }
        return nil
    }

    public static func truncate(_ s: String, max: Int = 100) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= max ? flat : String(flat.prefix(max)) + "…"
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test 2>&1 | tail -3`
Expected: PASS, 20 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: extract waiting description from transcript tail"
```

---

### Task 6: Session model, builder, age formatting, aggregate

**Files:**
- Create: `Sources/ClaudeLightsCore/Session.swift`, `Tests/ClaudeLightsCoreTests/SessionBuilderTests.swift`

**Interfaces:**
- Consumes: `AgentRecord`, `StateMapper.light`, `TmuxMapper.target`, `TmuxPane`, `LightState`
- Produces:
  - `struct Session: Identifiable` — `id: String` (sessionId or pid string), `pid: Int`, `cwd: String`, `projectName: String`, `derivedName: String`, `light: LightState`, `statusText: String`, `statusUpdatedAt: Date?`, `tmuxSession: String?`, `tmuxWindow: String?` (public memberwise init)
  - `SessionBuilder.build(records:pidTtys:panes:) -> [Session]` — interactive only, sorted red→yellow→green then by projectName
  - `SessionBuilder.label(for: LightState) -> String` — "Waiting for you" / "Working" / "Idle" / "Unknown"
  - `AgeFormatter.string(from: Date?, now: Date) -> String` — "just now" / "3m ago" / "2h ago" / "1d ago", "" for nil
  - `Aggregate.overall(_ sessions: [Session], hasError: Bool) -> LightState`

- [ ] **Step 1: Write failing tests**

`Tests/ClaudeLightsCoreTests/SessionBuilderTests.swift`:
```swift
import XCTest
@testable import ClaudeLightsCore

final class SessionBuilderTests: XCTestCase {
    func makeRecord(pid: Int, cwd: String, status: String, name: String = "x") -> AgentRecord {
        AgentRecord(pid: pid, cwd: cwd, kind: "interactive", sessionId: "s\(pid)",
                    name: name, status: status, statusUpdatedAt: 1783872850584)
    }

    func testBuildFiltersSortsAndJoins() {
        let records = [
            makeRecord(pid: 1, cwd: "/Users/dev/alpha", status: "idle"),
            makeRecord(pid: 2, cwd: "/Users/dev/beta", status: "busy"),
            makeRecord(pid: 3, cwd: "/Users/dev/gamma", status: "waiting"),
            AgentRecord(pid: 4, cwd: "/tmp", kind: "background", status: "busy"),
            AgentRecord(pid: nil, cwd: "/tmp", kind: "interactive", status: "busy"),
        ]
        let panes = [TmuxPane(tty: "/dev/ttys001", sessionName: "main", windowIndex: "3", paneId: "%1")]
        let sessions = SessionBuilder.build(records: records, pidTtys: [2: "/dev/ttys001"], panes: panes)

        XCTAssertEqual(sessions.map(\.light), [.red, .yellow, .green])
        XCTAssertEqual(sessions.map(\.projectName), ["gamma", "beta", "alpha"])
        XCTAssertEqual(sessions[1].tmuxSession, "main")
        XCTAssertEqual(sessions[1].tmuxWindow, "3")
        XCTAssertNil(sessions[0].tmuxSession)
        XCTAssertEqual(sessions[0].statusText, "Waiting for you")
        XCTAssertEqual(sessions[0].id, "s3")
        XCTAssertNotNil(sessions[0].statusUpdatedAt)
    }

    func testAgeFormatter() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(AgeFormatter.string(from: Date(timeIntervalSince1970: 9_970), now: now), "just now")
        XCTAssertEqual(AgeFormatter.string(from: Date(timeIntervalSince1970: 9_700), now: now), "5m ago")
        XCTAssertEqual(AgeFormatter.string(from: Date(timeIntervalSince1970: 2_800), now: now), "2h ago")
        XCTAssertEqual(AgeFormatter.string(from: nil, now: now), "")
    }

    func testAggregate() {
        func s(_ light: LightState) -> Session {
            Session(id: UUID().uuidString, pid: 1, cwd: "/", projectName: "p", derivedName: "",
                    light: light, statusText: "", statusUpdatedAt: nil, tmuxSession: nil, tmuxWindow: nil)
        }
        XCTAssertEqual(Aggregate.overall([], hasError: false), .gray)
        XCTAssertEqual(Aggregate.overall([s(.green), s(.red), s(.yellow)], hasError: false), .red)
        XCTAssertEqual(Aggregate.overall([s(.green), s(.yellow)], hasError: false), .yellow)
        XCTAssertEqual(Aggregate.overall([s(.green)], hasError: false), .green)
        XCTAssertEqual(Aggregate.overall([s(.red)], hasError: true), .gray)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test 2>&1 | tail -5`
Expected: compile error "cannot find 'Session'".

- [ ] **Step 3: Implement**

`Sources/ClaudeLightsCore/Session.swift`:
```swift
import Foundation

public struct Session: Identifiable, Equatable, Sendable {
    public let id: String
    public let pid: Int
    public let cwd: String
    public let projectName: String
    public let derivedName: String
    public let light: LightState
    public let statusText: String
    public let statusUpdatedAt: Date?
    public let tmuxSession: String?
    public let tmuxWindow: String?

    public init(id: String, pid: Int, cwd: String, projectName: String, derivedName: String,
                light: LightState, statusText: String, statusUpdatedAt: Date?,
                tmuxSession: String?, tmuxWindow: String?) {
        self.id = id; self.pid = pid; self.cwd = cwd
        self.projectName = projectName; self.derivedName = derivedName
        self.light = light; self.statusText = statusText
        self.statusUpdatedAt = statusUpdatedAt
        self.tmuxSession = tmuxSession; self.tmuxWindow = tmuxWindow
    }
}

public enum SessionBuilder {
    public static func build(records: [AgentRecord],
                             pidTtys: [Int: String],
                             panes: [TmuxPane]) -> [Session] {
        records
            .filter { $0.kind == "interactive" }
            .compactMap { record -> Session? in
                guard let pid = record.pid, let cwd = record.cwd else { return nil }
                let light = StateMapper.light(status: record.status, state: record.state)
                let pane = TmuxMapper.target(forPid: pid, pidTtys: pidTtys, panes: panes)
                return Session(
                    id: record.sessionId ?? String(pid),
                    pid: pid,
                    cwd: cwd,
                    projectName: (cwd as NSString).lastPathComponent,
                    derivedName: record.name ?? "",
                    light: light,
                    statusText: label(for: light),
                    statusUpdatedAt: record.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                    tmuxSession: pane?.sessionName,
                    tmuxWindow: pane?.windowIndex)
            }
            .sorted { lhs, rhs in
                if lhs.light != rhs.light { return lhs.light < rhs.light }
                return lhs.projectName.localizedCompare(rhs.projectName) == .orderedAscending
            }
    }

    public static func label(for light: LightState) -> String {
        switch light {
        case .red: return "Waiting for you"
        case .yellow: return "Working"
        case .green: return "Idle"
        case .gray: return "Unknown"
        }
    }
}

public enum AgeFormatter {
    public static func string(from date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

public enum Aggregate {
    public static func overall(_ sessions: [Session], hasError: Bool) -> LightState {
        if hasError || sessions.isEmpty { return .gray }
        return sessions.map(\.light).min() ?? .gray
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test 2>&1 | tail -3`
Expected: PASS, 23 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: build sorted session models with age and aggregate state"
```

---

### Task 7: Transition detection (notification trigger)

**Files:**
- Create: `Sources/ClaudeLightsCore/TransitionDetector.swift`, `Tests/ClaudeLightsCoreTests/TransitionDetectorTests.swift`

**Interfaces:**
- Consumes: `Session`, `LightState`
- Produces: `TransitionDetector.newlyRed(previous: [String: LightState]?, current: [Session]) -> [Session]` — `previous == nil` means first snapshot (returns `[]`); a session is "newly red" when red now and its previous state was anything but red (including absent).

- [ ] **Step 1: Write failing tests**

`Tests/ClaudeLightsCoreTests/TransitionDetectorTests.swift`:
```swift
import XCTest
@testable import ClaudeLightsCore

final class TransitionDetectorTests: XCTestCase {
    func s(_ id: String, _ light: LightState) -> Session {
        Session(id: id, pid: 1, cwd: "/", projectName: "p", derivedName: "",
                light: light, statusText: "", statusUpdatedAt: nil, tmuxSession: nil, tmuxWindow: nil)
    }

    func testFirstSnapshotNeverNotifies() {
        XCTAssertEqual(TransitionDetector.newlyRed(previous: nil, current: [s("a", .red)]), [])
    }

    func testYellowToRedNotifies() {
        let out = TransitionDetector.newlyRed(previous: ["a": .yellow], current: [s("a", .red)])
        XCTAssertEqual(out.map(\.id), ["a"])
    }

    func testStayingRedDoesNotRepeat() {
        XCTAssertEqual(TransitionDetector.newlyRed(previous: ["a": .red], current: [s("a", .red)]), [])
    }

    func testNewSessionAppearingRedNotifies() {
        let out = TransitionDetector.newlyRed(previous: [:], current: [s("b", .red)])
        XCTAssertEqual(out.map(\.id), ["b"])
    }

    func testNonRedNeverNotifies() {
        XCTAssertEqual(TransitionDetector.newlyRed(previous: ["a": .red], current: [s("a", .green)]), [])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test 2>&1 | tail -5`
Expected: compile error "cannot find 'TransitionDetector'".

- [ ] **Step 3: Implement**

`Sources/ClaudeLightsCore/TransitionDetector.swift`:
```swift
import Foundation

public enum TransitionDetector {
    /// Sessions that just turned red. `previous == nil` marks the first poll
    /// snapshot after launch: never notify then, to avoid a startup flood.
    public static func newlyRed(previous: [String: LightState]?,
                                current: [Session]) -> [Session] {
        guard let previous else { return [] }
        return current.filter { $0.light == .red && previous[$0.id] != .red }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test 2>&1 | tail -3`
Expected: PASS, 28 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: detect transitions into red for notifications"
```

---

### Task 8: App shell — Shell runner, Poller, SessionStore, AppDelegate skeleton

**Files:**
- Create: `Sources/ClaudeLights/Shell.swift`, `Sources/ClaudeLights/Poller.swift`, `Sources/ClaudeLights/SessionStore.swift`, `Sources/ClaudeLights/AppDelegate.swift`
- Modify: `Sources/ClaudeLights/main.swift`

**Interfaces:**
- Consumes: everything from Core.
- Produces:
  - `Shell.run(_ executable: String, _ arguments: [String]) -> String?` (nil on failure/nonzero exit)
  - `BinaryLocator.locate(_ name: String) -> String?`
  - `final class SessionStore: ObservableObject` with `@Published var sessions: [Session]`, `@Published var errorText: String?` (main-actor)
  - `final class Poller` with `var onSnapshot: (([Session], String?) -> Void)?`, `var onNewlyRed: (([Session]) -> Void)?`, `func start()` — callbacks invoked on main thread every 2 s
  - `final class AppDelegate: NSObject, NSApplicationDelegate` wiring everything (extended in later tasks)

- [ ] **Step 1: Implement Shell + BinaryLocator**

`Sources/ClaudeLights/Shell.swift`:
```swift
import Foundation

enum Shell {
    /// Runs a subprocess and returns stdout, or nil on any failure.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum BinaryLocator {
    /// GUI apps get a bare PATH; probe common install locations, then a login shell.
    static func locate(_ name: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/.claude/local/\(name)",
            "/usr/bin/\(name)",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        if let found = Shell.run("/bin/zsh", ["-lc", "command -v \(name)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !found.isEmpty {
            return found
        }
        return nil
    }
}
```

- [ ] **Step 2: Implement SessionStore + Poller**

`Sources/ClaudeLights/SessionStore.swift`:
```swift
import Foundation
import ClaudeLightsCore

final class SessionStore: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var errorText: String?
}
```

`Sources/ClaudeLights/Poller.swift`:
```swift
import Foundation
import ClaudeLightsCore

final class Poller {
    var onSnapshot: (([Session], String?) -> Void)?
    var onNewlyRed: (([Session]) -> Void)?

    private let tmuxPath = BinaryLocator.locate("tmux")
    private let queue = DispatchQueue(label: "com.agate.claudelights.poller")
    private var timer: DispatchSourceTimer?
    private var previous: [String: LightState]?

    func start(interval: TimeInterval = 2.0) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func poll() {
        var error: String?
        if !FileManager.default.fileExists(atPath: SessionRegistry.defaultDir.path) {
            error = "Claude Code session registry not found (~/.claude/sessions)"
        }
        let records = SessionRegistry.load()

        let pids = records.compactMap { $0.kind == "interactive" ? $0.pid : nil }
        var pidTtys: [Int: String] = [:]
        if !pids.isEmpty,
           let psOut = Shell.run("/bin/ps", ["-o", "pid=,tty=", "-p",
                                             pids.map(String.init).joined(separator: ",")]) {
            pidTtys = TmuxMapper.parsePidTtys(psOut)
        }

        var panes: [TmuxPane] = []
        if let tmuxPath,
           let panesOut = Shell.run(tmuxPath, ["list-panes", "-a", "-F", TmuxMapper.panesFormat]) {
            panes = TmuxMapper.parsePanes(panesOut)
        }

        let sessions = SessionBuilder.build(records: records, pidTtys: pidTtys, panes: panes)
        let newlyRed = TransitionDetector.newlyRed(previous: previous, current: sessions)
        previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.light) })

        DispatchQueue.main.async { [weak self] in
            self?.onSnapshot?(sessions, error)
            if !newlyRed.isEmpty { self?.onNewlyRed?(newlyRed) }
        }
    }
}
```

- [ ] **Step 3: AppDelegate skeleton + main**

`Sources/ClaudeLights/AppDelegate.swift`:
```swift
import AppKit
import ClaudeLightsCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    let poller = Poller()

    func applicationDidFinishLaunching(_ notification: Notification) {
        poller.onSnapshot = { [weak self] sessions, error in
            self?.store.sessions = sessions
            self?.store.errorText = error
        }
        poller.start()
    }
}
```

`Sources/ClaudeLights/main.swift` (replace content):
```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 4: Verify build + tests**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build succeeds; 28 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: app shell with registry poller and session store"
```

---

### Task 9: Tray icon + menu

**Files:**
- Create: `Sources/ClaudeLights/StatusIcon.swift`, `Sources/ClaudeLights/StatusItemController.swift`
- Modify: `Sources/ClaudeLights/AppDelegate.swift`

**Interfaces:**
- Consumes: `Session`, `LightState`, `Aggregate.overall`, `AgeFormatter.string`, `SessionBuilder.label`
- Produces:
  - `StatusIcon.image(for: LightState) -> NSImage`, `StatusIcon.color(_ light: LightState) -> NSColor`
  - `final class StatusItemController: NSObject` with `var onJump: ((Session) -> Void)?`, `var onToggleBar: (() -> Void)?`, `func update(sessions: [Session], error: String?)`

- [ ] **Step 1: Implement StatusIcon**

`Sources/ClaudeLights/StatusIcon.swift`:
```swift
import AppKit
import ClaudeLightsCore

enum StatusIcon {
    static func color(_ light: LightState) -> NSColor {
        switch light {
        case .red: return .systemRed
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .gray: return .systemGray
        }
    }

    static func image(for light: LightState, diameter: CGFloat = 10) -> NSImage {
        let size = NSSize(width: diameter + 4, height: diameter + 4)
        let image = NSImage(size: size, flipped: false) { rect in
            color(light).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
```

- [ ] **Step 2: Implement StatusItemController**

`Sources/ClaudeLights/StatusItemController.swift`:
```swift
import AppKit
import ServiceManagement
import ClaudeLightsCore

final class StatusItemController: NSObject {
    var onJump: ((Session) -> Void)?
    var onToggleBar: (() -> Void)?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var sessions: [Session] = []

    func update(sessions: [Session], error: String?) {
        self.sessions = sessions
        item.button?.image = StatusIcon.image(for: Aggregate.overall(sessions, hasError: error != nil), diameter: 12)
        item.button?.toolTip = "Claude Lights"
        item.menu = buildMenu(error: error)
    }

    private func buildMenu(error: String?) -> NSMenu {
        let menu = NSMenu()
        if let error {
            menu.addItem(disabledItem(error))
        } else if sessions.isEmpty {
            menu.addItem(disabledItem("No Claude sessions"))
        }
        for (index, session) in sessions.enumerated() {
            var title = "\(session.projectName) — \(session.statusText)"
            let age = AgeFormatter.string(from: session.statusUpdatedAt)
            if !age.isEmpty { title += " · \(age)" }
            if session.tmuxSession == nil { title += " · not in tmux" }
            let mi = NSMenuItem(title: title, action: #selector(jumpItem(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = index
            mi.image = StatusIcon.image(for: session.light)
            mi.toolTip = "\(session.cwd)\n\(session.derivedName)"
            menu.addItem(mi)
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Show/Hide Light Bar", action: #selector(toggleBar), keyEquivalent: "b")
        toggle.target = self
        menu.addItem(toggle)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        if Bundle.main.bundleIdentifier != nil {
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } // else: left targetless -> disabled under `swift run` (no bundle)
        menu.addItem(login)

        menu.addItem(NSMenuItem(title: "Quit Claude Lights",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    @objc private func jumpItem(_ sender: NSMenuItem) {
        guard sessions.indices.contains(sender.tag) else { return }
        onJump?(sessions[sender.tag])
    }

    @objc private func toggleBar() { onToggleBar?() }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }
}
```

- [ ] **Step 3: Wire into AppDelegate**

Replace `Sources/ClaudeLights/AppDelegate.swift`:
```swift
import AppKit
import ClaudeLightsCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    let poller = Poller()
    private var statusController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController()

        poller.onSnapshot = { [weak self] sessions, error in
            guard let self else { return }
            self.store.sessions = sessions
            self.store.errorText = error
            self.statusController.update(sessions: sessions, error: error)
        }
        poller.start()
    }
}
```

- [ ] **Step 4: Verify build + smoke run**

Run: `swift build 2>&1 | tail -3`
Expected: build succeeds.
Run: `.build/debug/ClaudeLights & APP_PID=$!; sleep 6; kill $APP_PID; wait $APP_PID 2>/dev/null; echo "smoke ok"` — app should run for 6 s without crashing (tray dot appears).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: tray icon with per-session menu and aggregate light"
```

---

### Task 10: Floating light bar

**Files:**
- Create: `Sources/ClaudeLights/FloatingBar.swift`
- Modify: `Sources/ClaudeLights/AppDelegate.swift`

**Interfaces:**
- Consumes: `SessionStore`, `Session`, `StatusIcon.color`
- Produces: `final class FloatingBar: NSObject, NSWindowDelegate` with `init(store: SessionStore, onJump: @escaping (Session) -> Void)`, `func refresh()`, `func toggle()`

- [ ] **Step 1: Implement FloatingBar + BarView**

`Sources/ClaudeLights/FloatingBar.swift`:
```swift
import AppKit
import SwiftUI
import ClaudeLightsCore

struct BarView: View {
    @ObservedObject var store: SessionStore
    var onJump: (Session) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(store.sessions) { session in
                Circle()
                    .fill(Color(StatusIcon.color(session.light)))
                    .frame(width: 12, height: 12)
                    .help("\(session.projectName) — \(session.statusText)")
                    .onTapGesture { onJump(session) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .fixedSize()
    }
}

final class FloatingBar: NSObject, NSWindowDelegate {
    private static let originKey = "barOrigin"
    private static let hiddenKey = "barHidden"

    private let panel: NSPanel
    private let store: SessionStore
    private var manuallyHidden = UserDefaults.standard.bool(forKey: FloatingBar.hiddenKey)

    init(store: SessionStore, onJump: @escaping (Session) -> Void) {
        self.store = store
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 28),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: BarView(store: store, onJump: onJump))
        restoreOrigin()
    }

    /// Re-fit size and show/hide according to session count and user toggle.
    func refresh() {
        if let host = panel.contentView as? NSHostingView<BarView> {
            let size = host.fittingSize
            if size.width > 0, size != panel.frame.size {
                panel.setContentSize(size)
            }
        }
        let shouldShow = !store.sessions.isEmpty && !manuallyHidden
        if shouldShow {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    func toggle() {
        manuallyHidden.toggle()
        UserDefaults.standard.set(manuallyHidden, forKey: FloatingBar.hiddenKey)
        refresh()
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set([panel.frame.origin.x, panel.frame.origin.y],
                                  forKey: FloatingBar.originKey)
    }

    private func restoreOrigin() {
        if let saved = UserDefaults.standard.array(forKey: FloatingBar.originKey) as? [Double],
           saved.count == 2 {
            panel.setFrameOrigin(NSPoint(x: saved[0], y: saved[1]))
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 240, y: frame.maxY - 44))
        }
    }
}
```

- [ ] **Step 2: Wire into AppDelegate**

In `Sources/ClaudeLights/AppDelegate.swift`, add a property and wiring (full file):
```swift
import AppKit
import ClaudeLightsCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    let poller = Poller()
    private var statusController: StatusItemController!
    private var bar: FloatingBar!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController()
        bar = FloatingBar(store: store) { session in
            print("jump requested: \(session.projectName)") // replaced in Task 11
        }
        statusController.onToggleBar = { [weak self] in self?.bar.toggle() }

        poller.onSnapshot = { [weak self] sessions, error in
            guard let self else { return }
            self.store.sessions = sessions
            self.store.errorText = error
            self.statusController.update(sessions: sessions, error: error)
            self.bar.refresh()
        }
        poller.start()
    }
}
```

- [ ] **Step 3: Verify build + smoke run**

Run: `swift build 2>&1 | tail -3 && (.build/debug/ClaudeLights & APP_PID=$!; sleep 6; kill $APP_PID; wait $APP_PID 2>/dev/null; echo "smoke ok")`
Expected: build succeeds; while running, a capsule with colored dots floats top-right (there is at least one live session: this one).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: always-on-top floating light bar with drag persistence"
```

---

### Task 11: Jumper (tmux switch + terminal activation)

**Files:**
- Create: `Sources/ClaudeLights/Jumper.swift`
- Modify: `Sources/ClaudeLights/AppDelegate.swift`

**Interfaces:**
- Consumes: `Session`, `Shell.run`, `BinaryLocator.locate`
- Produces: `final class Jumper` with `func jump(to session: Session)`

- [ ] **Step 1: Implement Jumper**

`Sources/ClaudeLights/Jumper.swift`:
```swift
import AppKit
import ClaudeLightsCore

final class Jumper {
    private let tmuxPath = BinaryLocator.locate("tmux")

    func jump(to session: Session) {
        if let tmuxPath, let tmuxSession = session.tmuxSession, let window = session.tmuxWindow {
            Shell.run(tmuxPath, ["switch-client", "-t", "\(tmuxSession):\(window)"])
        }
        activateTerminal()
    }

    /// Finds the GUI app hosting the attached tmux client by walking up its
    /// process ancestry; falls back to well-known terminal apps.
    private func activateTerminal() {
        if let tmuxPath,
           let out = Shell.run(tmuxPath, ["list-clients", "-F", "#{client_pid}"]) {
            for pidLine in out.split(separator: "\n") {
                guard var pid = Int32(pidLine.trimmingCharacters(in: .whitespaces)) else { continue }
                for _ in 0..<10 {
                    if let app = NSRunningApplication(processIdentifier: pid),
                       app.activationPolicy == .regular {
                        app.activate(options: [.activateIgnoringOtherApps])
                        return
                    }
                    guard let ppidOut = Shell.run("/bin/ps", ["-o", "ppid=", "-p", String(pid)]),
                          let ppid = Int32(ppidOut.trimmingCharacters(in: .whitespacesAndNewlines)),
                          ppid > 1 else { break }
                    pid = ppid
                }
            }
        }
        fallbackActivate()
    }

    private func fallbackActivate() {
        let known = ["iTerm2", "Ghostty", "WezTerm", "kitty", "Alacritty", "Terminal"]
        for name in known {
            if let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.localizedName == name }) {
                app.activate(options: [.activateIgnoringOtherApps])
                return
            }
        }
    }
}
```

- [ ] **Step 2: Wire into AppDelegate**

In `AppDelegate`, add `private let jumper = Jumper()` and replace the two jump closures:
```swift
        bar = FloatingBar(store: store) { [weak self] session in
            self?.jumper.jump(to: session)
        }
        statusController.onJump = { [weak self] session in
            self?.jumper.jump(to: session)
        }
```

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | tail -3`
Expected: build succeeds. (Behavior verified end-to-end in Task 13.)

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: jump to session tmux window and activate its terminal"
```

---

### Task 12: Notifier + red-transition wiring

**Files:**
- Create: `Sources/ClaudeLights/Notifier.swift`
- Modify: `Sources/ClaudeLights/AppDelegate.swift`

**Interfaces:**
- Consumes: `Session`, `TranscriptReader`
- Produces: `final class Notifier: NSObject, UNUserNotificationCenterDelegate` with `var onJump: ((String) -> Void)?` (session id), `func setup()`, `func notify(_ session: Session, description: String?)`

- [ ] **Step 1: Implement Notifier**

`Sources/ClaudeLights/Notifier.swift`:
```swift
import AppKit
import UserNotifications
import ClaudeLightsCore

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onJump: ((String) -> Void)?
    private var authorized = false
    /// UNUserNotificationCenter traps when the process has no bundle (swift run).
    private let hasBundle = Bundle.main.bundleIdentifier != nil

    func setup() {
        guard hasBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    func notify(_ session: Session, description: String?) {
        guard hasBundle, authorized else {
            NSSound(named: "Ping")?.play()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "\(session.projectName) needs you"
        if !session.derivedName.isEmpty { content.subtitle = session.derivedName }
        content.body = description ?? "Waiting for your input"
        content.sound = .default
        content.userInfo = ["sessionId": session.id]
        let request = UNNotificationRequest(identifier: session.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["sessionId"] as? String {
            onJump?(id)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
```

- [ ] **Step 2: Wire into AppDelegate (final full file)**

`Sources/ClaudeLights/AppDelegate.swift`:
```swift
import AppKit
import ClaudeLightsCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    let poller = Poller()
    private let jumper = Jumper()
    private let notifier = Notifier()
    private var statusController: StatusItemController!
    private var bar: FloatingBar!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController()
        bar = FloatingBar(store: store) { [weak self] session in
            self?.jumper.jump(to: session)
        }
        statusController.onJump = { [weak self] session in
            self?.jumper.jump(to: session)
        }
        statusController.onToggleBar = { [weak self] in self?.bar.toggle() }

        notifier.setup()
        notifier.onJump = { [weak self] sessionId in
            guard let session = self?.store.sessions.first(where: { $0.id == sessionId }) else { return }
            self?.jumper.jump(to: session)
        }

        poller.onSnapshot = { [weak self] sessions, error in
            guard let self else { return }
            self.store.sessions = sessions
            self.store.errorText = error
            self.statusController.update(sessions: sessions, error: error)
            self.bar.refresh()
        }
        poller.onNewlyRed = { [weak self] sessions in
            for session in sessions {
                let lines = TranscriptReader.tailLines(
                    of: TranscriptReader.transcriptURL(cwd: session.cwd, sessionId: session.id))
                let description = TranscriptReader.waitingDescription(fromJSONLines: lines)
                self?.notifier.notify(session, description: description)
            }
        }
        poller.start()
    }
}
```

- [ ] **Step 3: Verify build + tests**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build succeeds; 28 tests PASS.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: notify with sound and description when a session turns red"
```

---

### Task 13: App bundle, README, live verification

**Files:**
- Create: `scripts/bundle.sh`, `README.md`

**Interfaces:**
- Produces: `build/ClaudeLights.app` (LSUIElement, ad-hoc signed — required for UserNotifications).

- [ ] **Step 1: Write bundle script**

`scripts/bundle.sh`:
```bash
#!/bin/bash
# Builds ClaudeLights.app from the SwiftPM release binary.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/ClaudeLights.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClaudeLights "$APP/Contents/MacOS/ClaudeLights"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.agate.ClaudeLights</string>
    <key>CFBundleName</key><string>Claude Lights</string>
    <key>CFBundleExecutable</key><string>ClaudeLights</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
echo "Built $APP"
```

Run: `chmod +x scripts/bundle.sh && scripts/bundle.sh`
Expected: "Built build/ClaudeLights.app".

- [ ] **Step 2: Write README**

`README.md`:
```markdown
# Claude Lights

A macOS menu bar app that shows every local Claude Code session as a traffic
light — red means a session is waiting for you, yellow means it is working,
green means it is idle/done. Includes an always-on-top floating light bar,
one-click jump to the session's tmux window, and a notification with sound
when a session starts waiting.

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
```

- [ ] **Step 3: Live verification of waiting-state value (spec open point)**

With the bundled app running, start a disposable Claude session and drive it into the waiting state, then observe the registry value:

```bash
cd /tmp && tmux new-session -d -s cl-verify 'claude "run: touch /tmp/cl-verify-file"'
sleep 20 && for f in ~/.claude/sessions/*.json; do cat "$f"; echo; done
```

Expected: the disposable session's file shows a non-busy, non-idle status while Claude waits for permission approval. Record the exact value. If `StateMapper` does not already map it to red, update the mapper + `StateMapperTests` with the real value and re-run `swift test`. Then clean up: `tmux kill-session -t cl-verify`.

- [ ] **Step 4: End-to-end manual acceptance**

With `open build/ClaudeLights.app`:
1. Tray dot visible, reflects aggregate state; menu lists this session (the home-dir project).
2. Floating bar visible with one dot per session; drag it, quit and relaunch, position restored.
3. Trigger the waiting state (Step 3's session): dot turns red, sorted first, notification with sound and description arrives.
4. Click the red dot → terminal comes forward and tmux switches to the session's window.
5. `Show/Hide Light Bar` toggles the bar; `Quit` exits cleanly.

Record any failures, fix, and re-verify before proceeding.

- [ ] **Step 5: Final commit**

```bash
git add -A && git commit -m "feat: app bundle script, README, live verification"
```
