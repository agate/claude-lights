import XCTest
@testable import ClaudeLightsCore

final class SessionBuilderTests: XCTestCase {
    func makeRecord(pid: Int, cwd: String, status: String, name: String = "x") -> AgentRecord {
        AgentRecord(pid: pid, cwd: cwd, kind: "interactive", sessionId: "s\(pid)",
                    name: name, status: status, statusUpdatedAt: 1783872850584,
                    waitingFor: status == "waiting" ? "permission prompt" : nil)
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
        XCTAssertEqual(sessions[1].tmuxPane, "%1")
        XCTAssertNil(sessions[0].tmuxSession)
        XCTAssertEqual(sessions[0].statusText, "Waiting for you")
        XCTAssertEqual(sessions[0].id, "s3")
        XCTAssertNotNil(sessions[0].statusUpdatedAt)
        XCTAssertEqual(sessions[0].waitingFor, "permission prompt")
        XCTAssertNil(sessions[1].waitingFor)
    }

    func testAgeFormatter() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(AgeFormatter.string(from: Date(timeIntervalSince1970: 9_970), now: now), "just now")
        XCTAssertEqual(AgeFormatter.string(from: Date(timeIntervalSince1970: 9_700), now: now), "5m ago")
        XCTAssertEqual(AgeFormatter.string(from: Date(timeIntervalSince1970: 2_800), now: now), "2h ago")
        XCTAssertEqual(AgeFormatter.string(from: nil, now: now), "")
    }

    func testSummaryLine() {
        let records = [
            makeRecord(pid: 1, cwd: "/Users/dev/alpha", status: "idle"),
            makeRecord(pid: 2, cwd: "/Users/dev/beta", status: "busy"),
            makeRecord(pid: 3, cwd: "/Users/dev/gamma", status: "waiting"),
        ]
        let panes = [TmuxPane(tty: "/dev/ttys001", sessionName: "main", windowIndex: "3", paneId: "%1")]
        let sessions = SessionBuilder.build(records: records, pidTtys: [2: "/dev/ttys001"], panes: panes)
        // statusUpdatedAt fixture is 1783872850584 ms; two minutes later:
        let now = Date(timeIntervalSince1970: 1783872850.584 + 120)

        XCTAssertEqual(sessions[0].summaryLine(now: now),
                       "gamma — Waiting for you (permission prompt) · 2m ago · not in tmux")
        XCTAssertEqual(sessions[1].summaryLine(now: now),
                       "beta — Working · 2m ago")
        // Idle sessions show an explicit idle duration instead of "ago".
        XCTAssertEqual(sessions[2].summaryLine(now: now),
                       "alpha — Idle for 2m · not in tmux")
    }

    func testTitleAndVisibilityFlowThrough() {
        let records = [
            makeRecord(pid: 2, cwd: "/Users/dev/beta", status: "busy"),
            makeRecord(pid: 3, cwd: "/Users/dev/gamma", status: "waiting"),
        ]
        let sessions = SessionBuilder.build(records: records, pidTtys: [:], panes: [],
                                            titles: ["s2": "Self-learn Swift programming"],
                                            visibleIds: ["s2"])
        // sorted red first: s3 (waiting), then s2 (busy)
        XCTAssertNil(sessions[0].title)
        XCTAssertFalse(sessions[0].isOnScreen)
        XCTAssertEqual(sessions[1].title, "Self-learn Swift programming")
        XCTAssertTrue(sessions[1].isOnScreen)
        // Title becomes the primary display name in the summary line.
        let now = Date(timeIntervalSince1970: 1783872850.584 + 120)
        XCTAssertEqual(sessions[1].summaryLine(now: now),
                       "Self-learn Swift programming — Working · 2m ago · not in tmux")
    }

    func testBrandNewSessionsShowGray() {
        let records = [
            makeRecord(pid: 1, cwd: "/Users/dev/alpha", status: "busy"),
            makeRecord(pid: 2, cwd: "/Users/dev/beta", status: "idle"),
        ]
        // s1 has no transcript yet (still starting up): gray regardless of status.
        let sessions = SessionBuilder.build(records: records, pidTtys: [:], panes: [],
                                            newIds: ["s1"])
        XCTAssertEqual(sessions.map(\.id), ["s2", "s1"]) // gray sorts last
        XCTAssertEqual(sessions.map(\.light), [.green, .gray])
        XCTAssertEqual(sessions[1].statusText, "Starting")
    }

    func testSeenGreenGetsDimmedLightAndSortsAfterUnseen() {
        let records = [
            makeRecord(pid: 1, cwd: "/Users/dev/alpha", status: "idle"),
            makeRecord(pid: 2, cwd: "/Users/dev/beta", status: "idle"),
        ]
        let sessions = SessionBuilder.build(records: records, pidTtys: [:], panes: [],
                                            seenIds: ["s1"])
        XCTAssertEqual(sessions.map(\.id), ["s2", "s1"]) // unseen green first
        XCTAssertEqual(sessions.map(\.light), [.green, .greenSeen])
        XCTAssertEqual(sessions[1].statusText, "Idle")
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
        XCTAssertEqual(Aggregate.overall([s(.greenSeen), s(.greenSeen)], hasError: false), .greenSeen)
        XCTAssertEqual(Aggregate.overall([s(.green), s(.greenSeen)], hasError: false), .green)
        XCTAssertEqual(Aggregate.overall([s(.red)], hasError: true), .gray)
    }
}
