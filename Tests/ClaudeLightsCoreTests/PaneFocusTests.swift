import XCTest
@testable import ClaudeLightsCore

/// A split tmux window shows several panes at once, but only the focused pane
/// has actually been read. These cover the pane-level half of that check.
final class PaneFocusTests: XCTestCase {
    private let sep = TmuxMapper.sep

    private func session(_ id: String, window: String, pane: String,
                         light: LightState = .green) -> Session {
        Session(id: id, pid: 1, cwd: "/tmp/\(id)", projectName: id, derivedName: id,
                light: light, statusText: "idle", statusUpdatedAt: nil,
                tmuxSession: "main", tmuxWindow: window, tmuxPane: pane)
    }

    func testParsePanesReadsActiveFlag() {
        let out = "/dev/ttys001\(sep)main\(sep)0\(sep)%0\(sep)1\n"
            + "/dev/ttys004\(sep)main\(sep)0\(sep)%1\(sep)0\n"
        let panes = TmuxMapper.parsePanes(out)
        XCTAssertEqual(panes.count, 2)
        XCTAssertTrue(panes[0].isActive)
        XCTAssertFalse(panes[1].isActive)
    }

    func testActivePaneIdsKeepsOnlyActiveOnes() {
        let out = "/dev/ttys001\(sep)main\(sep)0\(sep)%0\(sep)1\n"
            + "/dev/ttys004\(sep)main\(sep)0\(sep)%1\(sep)0\n"
            + "/dev/ttys007\(sep)main\(sep)1\(sep)%2\(sep)1\n"
        let ids = TmuxMapper.activePaneIds(TmuxMapper.parsePanes(out))
        XCTAssertEqual(ids, ["%0", "%2"])
    }

    /// The reported bug: two panes in one window, one focused — the other one
    /// must NOT be marked read just because it shares the window.
    func testOnlyTheActivePaneInAWindowIsFocused() {
        let sessions = [session("a", window: "0", pane: "%0"),
                        session("b", window: "0", pane: "%1")]
        let focused = SeenTracker.focusedIds(sessions: sessions,
                                             focusedSessionName: "main",
                                             activeWindows: ["main:0"],
                                             activePaneIds: ["%0"])
        XCTAssertEqual(focused, ["a"])
    }

    func testPaneInAnInactiveWindowIsNotFocused() {
        let sessions = [session("a", window: "1", pane: "%9")]
        let focused = SeenTracker.focusedIds(sessions: sessions,
                                             focusedSessionName: "main",
                                             activeWindows: ["main:0"],
                                             activePaneIds: ["%9"])
        XCTAssertTrue(focused.isEmpty)
    }

    func testNoFocusedTerminalMeansNothingFocused() {
        let sessions = [session("a", window: "0", pane: "%0")]
        XCTAssertTrue(SeenTracker.focusedIds(sessions: sessions,
                                             focusedSessionName: nil,
                                             activeWindows: ["main:0"],
                                             activePaneIds: ["%0"]).isEmpty)
    }

    /// No pane id (not in tmux, or tmux lookup failed) must never auto-mark.
    func testSessionWithoutPaneIdIsNeverFocused() {
        let s = Session(id: "a", pid: 1, cwd: "/tmp/a", projectName: "a", derivedName: "a",
                        light: .green, statusText: "idle", statusUpdatedAt: nil,
                        tmuxSession: "main", tmuxWindow: "0", tmuxPane: nil)
        XCTAssertTrue(SeenTracker.focusedIds(sessions: [s],
                                             focusedSessionName: "main",
                                             activeWindows: ["main:0"],
                                             activePaneIds: ["%0"]).isEmpty)
    }
}
