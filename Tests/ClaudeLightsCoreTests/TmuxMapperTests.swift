import XCTest
@testable import ClaudeLightsCore

final class TmuxMapperTests: XCTestCase {
    let sep = TmuxMapper.sep
    lazy var panesFixture = "/dev/ttys001\(sep)main\(sep)0\(sep)%0\n/dev/ttys004\(sep)main\(sep)1\(sep)%1\n/dev/ttys007\(sep)work session\(sep)2\(sep)%5\n"
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

    func testParseClients() {
        let out = "/dev/ttys002\(sep)501\(sep)main\n/dev/ttys009\(sep)733\(sep)work session\n"
        let clients = TmuxMapper.parseClients(out)
        XCTAssertEqual(clients.count, 2)
        XCTAssertEqual(clients[0].tty, "/dev/ttys002")
        XCTAssertEqual(clients[0].pid, 501)
        XCTAssertEqual(clients[0].sessionName, "main")
        XCTAssertEqual(clients[1].pid, 733)
        XCTAssertEqual(clients[1].sessionName, "work session")
        XCTAssertEqual(TmuxMapper.parseClients("").count, 0)
        XCTAssertEqual(TmuxMapper.parseClients("/dev/ttys002\(sep)bad\(sep)main\n").count, 0)
    }

    func testParseActiveAttachedWindows() {
        let windows = "main\(sep)0\(sep)0\nmain\(sep)1\(sep)1\nother\(sep)2\(sep)1\n"
        let active = TmuxMapper.parseActiveAttachedWindows(attachedSessions: ["main"],
                                                           windowsOutput: windows)
        // main:1 is active in an attached session; other:2 is active but detached.
        XCTAssertEqual(active, ["main:1"])
    }

    func testAttachCommandQuotesSessionNames() {
        XCTAssertEqual(
            TmuxMapper.attachCommand(tmuxPath: "/opt/homebrew/bin/tmux", session: "main"),
            "/opt/homebrew/bin/tmux attach -t 'main'")
        XCTAssertEqual(
            TmuxMapper.attachCommand(tmuxPath: "/usr/local/bin/tmux", session: "work session"),
            "/usr/local/bin/tmux attach -t 'work session'")
        // Single quotes in the name must not break out of the shell quoting.
        XCTAssertEqual(
            TmuxMapper.attachCommand(tmuxPath: "/usr/bin/tmux", session: "it's"),
            "/usr/bin/tmux attach -t 'it'\\''s'")
    }

    func testEmptyInputs() {
        XCTAssertEqual(TmuxMapper.parsePanes("").count, 0)
        XCTAssertEqual(TmuxMapper.parsePidTtys("").count, 0)
    }
}
