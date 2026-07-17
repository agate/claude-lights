import XCTest
@testable import ClaudeLightsCore

final class SessionBuilderTests: XCTestCase {
    func makeRecord(pid: Int, cwd: String, status: String, name: String = "x") -> AgentRecord {
        AgentRecord(pid: pid, cwd: cwd, kind: "interactive", sessionId: "s\(pid)",
                    name: name, status: status, startedAt: Double(pid) * 1000,
                    statusUpdatedAt: 1783872850584,
                    waitingFor: status == "waiting" ? "permission prompt" : nil)
    }

    func testBuildFiltersAndJoins() {
        let records = [
            makeRecord(pid: 1, cwd: "/Users/dev/alpha", status: "idle"),
            makeRecord(pid: 2, cwd: "/Users/dev/beta", status: "busy"),
            makeRecord(pid: 3, cwd: "/Users/dev/gamma", status: "waiting"),
            AgentRecord(pid: 4, cwd: "/tmp", kind: "background", status: "busy"),
            AgentRecord(pid: nil, cwd: "/tmp", kind: "interactive", status: "busy"),
        ]
        let panes = [TmuxPane(tty: "/dev/ttys001", sessionName: "main", windowIndex: "3", paneId: "%1")]
        let sessions = SessionBuilder.build(records: records, pidTtys: [2: "/dev/ttys001"], panes: panes)

        // Stable order by launch time: alpha (s1), beta (s2), gamma (s3).
        XCTAssertEqual(sessions.map(\.projectName), ["alpha", "beta", "gamma"])
        XCTAssertEqual(sessions.map(\.light), [.green, .yellow, .red])
        XCTAssertEqual(sessions[1].tmuxSession, "main")
        XCTAssertEqual(sessions[1].tmuxWindow, "3")
        XCTAssertEqual(sessions[1].tmuxPane, "%1")
        // gamma is the waiting one, now last by launch order.
        XCTAssertEqual(sessions[2].id, "s3")
        XCTAssertNil(sessions[2].tmuxSession)
        XCTAssertEqual(sessions[2].statusText, "Waiting for you")
        XCTAssertEqual(sessions[2].waitingFor, "permission prompt")
        XCTAssertNil(sessions[1].waitingFor)
        XCTAssertNotNil(sessions[0].statusUpdatedAt)
    }

    func testSessionCarriesItsOwnTTY() {
        let records = [
            makeRecord(pid: 5, cwd: "/Users/dev/bare", status: "busy"), // plain terminal, no tmux
            makeRecord(pid: 6, cwd: "/Users/dev/intmux", status: "busy"),
        ]
        let panes = [TmuxPane(tty: "/dev/ttys009", sessionName: "main", windowIndex: "1", paneId: "%2")]
        let sessions = SessionBuilder.build(records: records,
                                            pidTtys: [5: "/dev/ttys004", 6: "/dev/ttys009"],
                                            panes: panes)
        // s5: bare terminal — has a tty but no tmux mapping.
        XCTAssertEqual(sessions[0].tty, "/dev/ttys004")
        XCTAssertNil(sessions[0].tmuxSession)
        // s6: in tmux — tty still recorded, plus tmux mapping.
        XCTAssertEqual(sessions[1].tty, "/dev/ttys009")
        XCTAssertEqual(sessions[1].tmuxSession, "main")
    }

    func testOrderIsStableAcrossStatusChanges() {
        func snapshot(_ betaStatus: String) -> [String] {
            let records = [
                makeRecord(pid: 1, cwd: "/Users/dev/alpha", status: "idle"),
                makeRecord(pid: 2, cwd: "/Users/dev/beta", status: betaStatus),
                makeRecord(pid: 3, cwd: "/Users/dev/gamma", status: "idle"),
            ]
            return SessionBuilder.build(records: records, pidTtys: [:], panes: []).map(\.id)
        }
        // beta changing state must not move it: order stays s1, s2, s3.
        XCTAssertEqual(snapshot("idle"), ["s1", "s2", "s3"])
        XCTAssertEqual(snapshot("busy"), ["s1", "s2", "s3"])
        XCTAssertEqual(snapshot("waiting"), ["s1", "s2", "s3"])
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

        // Stable launch order: alpha (idle), beta (busy), gamma (waiting).
        // Idle sessions show an explicit idle duration instead of "ago".
        XCTAssertEqual(sessions[0].summaryLine(now: now),
                       "alpha — Idle for 2m · not in tmux")
        XCTAssertEqual(sessions[1].summaryLine(now: now),
                       "beta — Working · 2m ago")
        XCTAssertEqual(sessions[2].summaryLine(now: now),
                       "gamma — Waiting for you (permission prompt) · 2m ago · not in tmux")
    }

    func testTitleAndVisibilityFlowThrough() {
        let records = [
            makeRecord(pid: 2, cwd: "/Users/dev/beta", status: "busy"),
            makeRecord(pid: 3, cwd: "/Users/dev/gamma", status: "waiting"),
        ]
        let sessions = SessionBuilder.build(records: records, pidTtys: [:], panes: [],
                                            titles: ["s2": "Self-learn Swift programming"],
                                            visibleIds: ["s2"])
        // Stable launch order: s2 (beta) then s3 (gamma).
        XCTAssertEqual(sessions[0].title, "Self-learn Swift programming")
        XCTAssertTrue(sessions[0].isOnScreen)
        XCTAssertNil(sessions[1].title)
        XCTAssertFalse(sessions[1].isOnScreen)
        // Title becomes the primary display name in the summary line.
        let now = Date(timeIntervalSince1970: 1783872850.584 + 120)
        XCTAssertEqual(sessions[0].summaryLine(now: now),
                       "Self-learn Swift programming — Working · 2m ago · not in tmux")
    }

    func testBackgroundTwinDrivesStateOfItsInteractiveSession() {
        // A session moved to background keeps a stale interactive record and
        // a live bg record under the same sessionId. Freshest record wins the
        // status; the interactive record provides the tmux jump target.
        let stale = AgentRecord(pid: 10, cwd: "/Users/dev/app", kind: "interactive",
                                sessionId: "s", name: "app-1a", status: "idle",
                                statusUpdatedAt: 1_000_000)
        let live = AgentRecord(pid: 20, cwd: "/Users/dev/app", kind: "bg",
                               sessionId: "s", name: "My task", status: "busy",
                               statusUpdatedAt: 2_000_000)
        let panes = [TmuxPane(tty: "/dev/ttys001", sessionName: "main", windowIndex: "1", paneId: "%3")]
        let sessions = SessionBuilder.build(records: [stale, live],
                                            pidTtys: [10: "/dev/ttys001"], panes: panes)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].light, .yellow)
        XCTAssertEqual(sessions[0].tmuxSession, "main")
        XCTAssertEqual(sessions[0].statusUpdatedAt, Date(timeIntervalSince1970: 2_000))
    }

    func testPureBackgroundJobsStayHidden() {
        let job = AgentRecord(pid: 30, cwd: "/tmp", kind: "bg", sessionId: "j",
                              name: "cron thing", status: "busy", statusUpdatedAt: 1000)
        XCTAssertEqual(SessionBuilder.build(records: [job], pidTtys: [:], panes: []).count, 0)
    }

    func testBrandNewSessionsShowGray() {
        let records = [
            makeRecord(pid: 1, cwd: "/Users/dev/alpha", status: "busy"),
            makeRecord(pid: 2, cwd: "/Users/dev/beta", status: "idle"),
        ]
        // s1 has no transcript yet (still starting up): gray regardless of status.
        let sessions = SessionBuilder.build(records: records, pidTtys: [:], panes: [],
                                            newIds: ["s1"])
        XCTAssertEqual(sessions.map(\.id), ["s1", "s2"]) // stable launch order
        XCTAssertEqual(sessions.map(\.light), [.gray, .green])
        XCTAssertEqual(sessions[0].statusText, "Starting")
    }

    func testSeenGreenGetsDimmedLightAndSortsAfterUnseen() {
        let records = [
            makeRecord(pid: 1, cwd: "/Users/dev/alpha", status: "idle"),
            makeRecord(pid: 2, cwd: "/Users/dev/beta", status: "idle"),
        ]
        let sessions = SessionBuilder.build(records: records, pidTtys: [:], panes: [],
                                            seenIds: ["s1"])
        XCTAssertEqual(sessions.map(\.id), ["s1", "s2"]) // stable launch order
        XCTAssertEqual(sessions.map(\.light), [.greenSeen, .green]) // s1 seen dims
        XCTAssertEqual(sessions[0].statusText, "Idle")
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
