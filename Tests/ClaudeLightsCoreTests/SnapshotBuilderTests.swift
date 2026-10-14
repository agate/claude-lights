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
