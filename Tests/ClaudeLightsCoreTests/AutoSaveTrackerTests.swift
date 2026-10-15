import XCTest
@testable import ClaudeLightsCore

final class AutoSaveTrackerTests: XCTestCase {
    func snap(_ name: String, windows: Int = 1, status: String? = "busy") -> Snapshot {
        let ws = (0..<windows).map { i in
            SnapshotWindow(index: i, name: "w\(i)", automaticRename: true, layout: "", width: 80,
                           height: 24, active: i == 0, zoomed: false,
                           panes: [SnapshotPane(index: 0, cwd: "/", active: true,
                                                claude: SnapshotClaude(sessionId: "s\(i)", status: status))])
        }
        return Snapshot(name: name, path: "/", windows: ws)
    }

    func testNewStateIsDueOnlyAfterSecondIdenticalTick() {
        var t = AutoSaveTracker()
        XCTAssertEqual(t.due([snap("work")]), [])
        XCTAssertEqual(t.due([snap("work")]).map(\.name), ["work"])
    }

    func testWrittenStateIsNotDueAgain() {
        var t = AutoSaveTracker()
        _ = t.due([snap("work")])
        for s in t.due([snap("work")]) { t.markWritten(s) }
        XCTAssertEqual(t.due([snap("work")]), [])
        XCTAssertEqual(t.due([snap("work")]), [])
    }

    func testFailedWriteIsRetriedNextTick() {
        var t = AutoSaveTracker()
        _ = t.due([snap("work")])
        XCTAssertEqual(t.due([snap("work")]).count, 1) // not marked written
        XCTAssertEqual(t.due([snap("work")]).count, 1)
    }

    func testStateThatKeepsChangingIsNotDue() {
        // E.g. a shutdown tearing panes down one tick at a time.
        var t = AutoSaveTracker()
        XCTAssertEqual(t.due([snap("work", windows: 3)]), [])
        XCTAssertEqual(t.due([snap("work", windows: 2)]), [])
        XCTAssertEqual(t.due([snap("work", windows: 1)]), [])
    }

    func testClaudeStatusChangeIsIgnored() {
        var t = AutoSaveTracker()
        _ = t.due([snap("work", status: "busy")])
        for s in t.due([snap("work", status: "busy")]) { t.markWritten(s) }
        XCTAssertEqual(t.due([snap("work", status: "idle")]), [])
        XCTAssertEqual(t.due([snap("work", status: "idle")]), [])
    }

    func testStructureChangeAfterWriteIsDueOnceStable() {
        var t = AutoSaveTracker()
        _ = t.due([snap("work")])
        for s in t.due([snap("work")]) { t.markWritten(s) }
        XCTAssertEqual(t.due([snap("work", windows: 2)]), [])
        XCTAssertEqual(t.due([snap("work", windows: 2)]).map { $0.windows.count }, [2])
    }

    func testSessionsAreTrackedIndependently() {
        var t = AutoSaveTracker()
        _ = t.due([snap("a")])
        XCTAssertEqual(t.due([snap("a"), snap("b")]).map(\.name), ["a"])
        XCTAssertEqual(t.due([snap("a"), snap("b")]).map(\.name), ["a", "b"])
    }

    func testForgetMakesAWrittenSessionDueAgain() {
        // The auto-saved file was deleted while the session kept running.
        var t = AutoSaveTracker()
        _ = t.due([snap("work")])
        for s in t.due([snap("work")]) { t.markWritten(s) }
        t.forget("work")
        XCTAssertEqual(t.due([snap("work")]), [])
        XCTAssertEqual(t.due([snap("work")]).map(\.name), ["work"])
    }
}
