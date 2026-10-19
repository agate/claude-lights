import XCTest
@testable import ClaudeLightsCore

final class MenuRowTests: XCTestCase {
    let updated = Date(timeIntervalSince1970: 1_000_000)

    func session(light: LightState, status: String, title: String? = nil,
                 waitingFor: String? = nil, tmux: String? = "main",
                 backgroundTasks: Int = 0) -> Session {
        var s = Session(id: "s1", pid: 1, cwd: "/Users/dev/alpha", projectName: "alpha",
                        derivedName: "alpha-1", light: light, statusText: status,
                        statusUpdatedAt: updated, tmuxSession: tmux, tmuxWindow: tmux.map { _ in "1" },
                        waitingFor: waitingFor, title: title)
        s.backgroundTasks = backgroundTasks
        return s
    }

    func testTitledSessionShowsProjectAsDetail() {
        let row = session(light: .green, status: "Idle", title: "Fix login")
            .menuRow(now: updated.addingTimeInterval(3 * 3600))
        XCTAssertEqual(row, MenuRow(title: "Fix login", subtitle: "Idle · alpha", age: "3h"))
    }

    func testUntitledSessionDoesNotRepeatProjectName() {
        let row = session(light: .yellow, status: "Working").menuRow(now: updated.addingTimeInterval(7))
        XCTAssertEqual(row, MenuRow(title: "alpha", subtitle: "Working", age: "7s"))
    }

    func testWaitReasonReplacesProject() {
        let row = session(light: .red, status: "Waiting for you", title: "T",
                          waitingFor: "permission prompt")
            .menuRow(now: updated.addingTimeInterval(30 * 60))
        XCTAssertEqual(row.subtitle, "Waiting for you · permission prompt")
        XCTAssertEqual(row.age, "30m")
    }

    func testNotInTmuxAndBackgroundTasks() {
        let row = session(light: .greenBg, status: "Idle", title: "T", tmux: nil, backgroundTasks: 2)
            .menuRow(now: updated.addingTimeInterval(2 * 86400))
        XCTAssertEqual(row.subtitle, "Idle · alpha · not in tmux · ⚙2")
        XCTAssertEqual(row.age, "2d")
    }

    func testBackgroundTasksHiddenWhileWorking() {
        // The count includes the foreground command while working, so it would be off by one.
        let row = session(light: .yellow, status: "Working", title: "T", backgroundTasks: 1)
            .menuRow(now: updated)
        XCTAssertEqual(row.subtitle, "Working · alpha")
    }

    func testMissingUpdateTimeGivesEmptyAge() {
        var s = session(light: .gray, status: "Unknown")
        s = Session(id: s.id, pid: s.pid, cwd: s.cwd, projectName: s.projectName,
                    derivedName: s.derivedName, light: s.light, statusText: s.statusText,
                    statusUpdatedAt: nil, tmuxSession: "main", tmuxWindow: "1")
        XCTAssertEqual(s.menuRow().age, "")
    }
}
