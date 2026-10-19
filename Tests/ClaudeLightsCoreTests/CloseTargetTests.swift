import XCTest
@testable import ClaudeLightsCore

final class CloseTargetTests: XCTestCase {
    func session(tmux: String? = nil, window: String? = nil, pane: String? = nil,
                 paneIndex: String? = nil, tty: String? = nil, herdr: String? = nil) -> Session {
        Session(id: "s1", pid: 1, cwd: "/Users/dev/alpha", projectName: "alpha",
                derivedName: "alpha-1", light: .green, statusText: "Idle", statusUpdatedAt: nil,
                tmuxSession: tmux, tmuxWindow: window, tmuxPane: pane, tty: tty,
                herdrPane: herdr, tmuxPaneIndex: paneIndex)
    }

    func testTmuxPaneWins() {
        let s = session(tmux: "main", window: "2", pane: "%12", tty: "/dev/ttys009")
        XCTAssertEqual(CloseTarget.for(s), .tmuxPane(id: "%12"))
    }

    func testHerdrPane() {
        XCTAssertEqual(CloseTarget.for(session(tty: "/dev/ttys020", herdr: "w5:p1")),
                       .herdrPane(id: "w5:p1"))
    }

    func testBareTerminalTab() {
        XCTAssertEqual(CloseTarget.for(session(tty: "/dev/ttys004")), .terminalTab(tty: "/dev/ttys004"))
    }

    func testProcessOnly() {
        XCTAssertEqual(CloseTarget.for(session()), .processOnly)
    }

    func testDescriptionNamesTheContainer() {
        let s = session(tmux: "main", window: "2", pane: "%12")
        XCTAssertEqual(CloseTarget.for(s).description(for: s),
                       "Claude will be stopped and its tmux pane (main:2) closed. Other panes in that window stay open.")
        let t = session(tty: "/dev/ttys004")
        XCTAssertEqual(CloseTarget.for(t).description(for: t),
                       "Claude will be stopped and its terminal tab closed.")
        XCTAssertEqual(CloseTarget.processOnly.description(for: session()),
                       "Claude will be stopped. Its window is left open.")
    }

    func testLocationLine() {
        XCTAssertEqual(session(tmux: "main", window: "2", pane: "%1", paneIndex: "1").locationLine,
                       "tmux: main:2.1")
        XCTAssertEqual(session(tmux: "main", window: "2", pane: "%1").locationLine, "tmux: main:2")
        XCTAssertEqual(session(tty: "/dev/ttys020", herdr: "w5:p1").locationLine, "herdr: w5:p1")
        XCTAssertEqual(session(tty: "/dev/ttys004").locationLine, "Terminal tab")
        XCTAssertEqual(session().locationLine, "No terminal")
    }

    func testParsePanesReadsPaneIndexAndToleratesOldFormat() {
        let sep = TmuxMapper.sep
        let panes = TmuxMapper.parsePanes(
            "/dev/ttys001\(sep)main\(sep)2\(sep)%7\(sep)1\(sep)3\n/dev/ttys002\(sep)main\(sep)0\(sep)%0\(sep)0\n")
        XCTAssertEqual(panes.map(\.paneIndex), ["3", nil])
        XCTAssertTrue(TmuxMapper.panesFormat.hasSuffix("#{pane_index}"))
    }

    func testBuilderCollectsEveryPidOfTheGroupAndPaneIndex() {
        let records = [
            AgentRecord(pid: 10, cwd: "/Users/dev/alpha", kind: "interactive", sessionId: "s",
                        status: "idle", startedAt: 1, statusUpdatedAt: 1),
            AgentRecord(pid: 11, cwd: "/Users/dev/alpha", kind: "bg", sessionId: "s",
                        status: "busy", startedAt: 2, statusUpdatedAt: 2),
        ]
        let panes = [TmuxPane(tty: "/dev/ttys001", sessionName: "main", windowIndex: "3",
                              paneId: "%1", paneIndex: "0")]
        let sessions = SessionBuilder.build(records: records, pidTtys: [10: "/dev/ttys001"], panes: panes)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].pids, [10, 11])
        XCTAssertEqual(sessions[0].tmuxPaneIndex, "0")
    }
}
