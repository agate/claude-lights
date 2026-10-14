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
            "Hold ⌥ to delete a saved session",
        ])
        XCTAssertEqual(e.map(\.enabled), [true, false, true, false])
        XCTAssertEqual(e.map(\.restoreName), ["blog", nil, nil, nil])
    }

    func testEveryRowIsDeletableEvenWhenRunningOrBroken() {
        let e = SnapshotMenu.entries([.ready(file("work", windows: 1, claudes: 1)),
                                      .unreadable("bad"), .downloading("cloud")],
                                     running: ["work"], timeZone: tz)
        XCTAssertEqual(e.map(\.deleteName), ["bad", "cloud", "work", nil, nil])
        XCTAssertEqual(e.last?.title, SnapshotMenu.deleteHint)
    }

    // Review Focus 5
    func testUnreadableAndDownloadingAreDisabled() {
        let e = SnapshotMenu.entries([.unreadable("bad"), .downloading("cloud")],
                                     running: [], timeZone: tz)
        XCTAssertEqual(e.map(\.title), ["bad (unreadable)", "cloud (downloading from iCloud…)",
                                        "Hold ⌥ to delete a saved session"])
        XCTAssertEqual(e.map(\.enabled), [false, false, false])
    }

    func testEmpty() {
        XCTAssertEqual(SnapshotMenu.entries([], running: [], timeZone: tz),
                       [SnapshotMenuEntry(title: "No saved sessions", restoreName: nil, enabled: false)])
    }

    func testRestoreAllDisabledWhenNothingRestorable() {
        let e = SnapshotMenu.entries([.ready(file("work", windows: 1, claudes: 1))],
                                     running: ["work"], timeZone: tz)
        XCTAssertEqual(e.dropLast().last,
                       SnapshotMenuEntry(title: "Restore All", restoreName: nil, enabled: false))
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
