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

    func testParseClients() {
        let out = "/dev/ttys002\tmain\n/dev/ttys009\twork session\n"
        let clients = TmuxMapper.parseClients(out)
        XCTAssertEqual(clients.count, 2)
        XCTAssertEqual(clients[0].tty, "/dev/ttys002")
        XCTAssertEqual(clients[0].sessionName, "main")
        XCTAssertEqual(clients[1].sessionName, "work session")
        XCTAssertEqual(TmuxMapper.parseClients("").count, 0)
    }

    func testParseActiveAttachedWindows() {
        let windows = "main\t0\t0\nmain\t1\t1\nother\t2\t1\n"
        let active = TmuxMapper.parseActiveAttachedWindows(attachedSessions: ["main"],
                                                           windowsOutput: windows)
        // main:1 is active in an attached session; other:2 is active but detached.
        XCTAssertEqual(active, ["main:1"])
    }

    func testEmptyInputs() {
        XCTAssertEqual(TmuxMapper.parsePanes("").count, 0)
        XCTAssertEqual(TmuxMapper.parsePidTtys("").count, 0)
    }
}
