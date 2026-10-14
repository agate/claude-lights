import XCTest
@testable import ClaudeLightsCore

final class RestorePlanTests: XCTestCase {
    func pane(_ i: Int, _ cwd: String, active: Bool = false, claude: String? = nil,
              command: String? = nil) -> SnapshotPane {
        SnapshotPane(index: i, cwd: cwd, active: active,
                     claude: claude.map { SnapshotClaude(sessionId: $0, cwd: cwd) },
                     command: command)
    }

    func testShellQuote() {
        XCTAssertEqual(RestorePlan.shellQuote("/Users/me/src"), "/Users/me/src")
        XCTAssertEqual(RestorePlan.shellQuote("/Users/me/my src"), "'/Users/me/my src'")
        XCTAssertEqual(RestorePlan.shellQuote("it's $HOME"), "'it'\"'\"'s $HOME'")
        XCTAssertEqual(RestorePlan.shellQuote(""), "''")
    }

    // Review Focus 3
    func testResumeLineQuotesCwdAndPrefersClaudeCwd() {
        var p = pane(0, "/pane cwd", claude: "abc")
        p.claude?.cwd = "/Users/me/it's here"
        XCTAssertEqual(RestorePlan.resumeLine(p),
                       "cd '/Users/me/it'\"'\"'s here' && claude --resume abc")
        p.claude?.cwd = nil
        XCTAssertEqual(RestorePlan.resumeLine(p), "cd '/pane cwd' && claude --resume abc")
        XCTAssertNil(RestorePlan.resumeLine(pane(0, "/x")))
    }

    func testNewSession() {
        let s = Snapshot(name: "work", path: "/src", windows: [
            SnapshotWindow(index: 1, name: "a", automaticRename: true, layout: "", width: 120,
                           height: 40, active: true, zoomed: false, panes: [pane(0, "/src")]),
        ])
        XCTAssertEqual(RestorePlan.newSession(s),
                       ["new-session", "-d", "-s", "work", "-c", "/src", "-x", "120", "-y", "40"])
    }

    func testMultiWindowMultiPaneZoomed() {
        let s = Snapshot(name: "work", path: "/src", windows: [
            SnapshotWindow(index: 1, name: "api", automaticRename: false, layout: "LAYOUT",
                           width: 200, height: 50, active: false, zoomed: true,
                           panes: [pane(0, "/src/api", claude: "abc"),
                                   pane(1, "/src/api", active: true, command: "npm run dev")]),
            SnapshotWindow(index: 2, name: "zsh", automaticRename: true, layout: "L2",
                           width: 200, height: 50, active: true, zoomed: false,
                           panes: [pane(0, "/src/web", active: true)]),
        ])
        XCTAssertEqual(RestorePlan.commands(s, baseIndex: 0), [
            ["move-window", "-s", "work:0", "-t", "work:1"],
            ["send-keys", "-t", "work:1", "cd /src/api && clear", "Enter"],
            ["split-window", "-d", "-t", "work:1", "-c", "/src/api"],
            ["select-layout", "-t", "work:1", "LAYOUT"],
            ["rename-window", "-t", "work:1", "api"],
            ["set-option", "-w", "-t", "work:1", "automatic-rename", "off"],
            ["send-keys", "-t", "work:1.0", "cd /src/api && claude --resume abc", "Enter"],
            ["send-keys", "-t", "work:1.1", "-l", "npm run dev"],
            ["select-pane", "-t", "work:1.1"],
            ["resize-pane", "-Z", "-t", "work:1"],
            ["new-window", "-d", "-t", "work:2", "-c", "/src/web"],
            ["rename-window", "-t", "work:2", "zsh"],
            ["set-option", "-w", "-t", "work:2", "automatic-rename", "on"],
            ["select-window", "-t", "work:2"],
        ])
    }

    func testNoMoveWhenFirstIndexMatchesBase() {
        let s = Snapshot(name: "w", path: "/src", windows: [
            SnapshotWindow(index: 1, name: "a", automaticRename: true, layout: "", width: 80,
                           height: 24, active: true, zoomed: false, panes: [pane(0, "/src")]),
        ])
        XCTAssertEqual(RestorePlan.commands(s, baseIndex: 1), [
            ["rename-window", "-t", "w:1", "a"],
            ["set-option", "-w", "-t", "w:1", "automatic-rename", "on"],
            ["select-window", "-t", "w:1"],
        ])
    }

    // Review Focus 4: single-pane windows are targeted by window, so
    // pane-base-index never matters for the loose snapshot.
    func testSinglePaneWindowTargetsWindowNotPaneIndex() {
        let s = Snapshot(name: SnapshotCodec.looseName, path: "/Users/me", windows: [
            SnapshotWindow(index: 1, name: "Fix login", automaticRename: false, layout: "",
                           width: 200, height: 50, active: true, zoomed: false,
                           panes: [pane(0, "/Users/me/a b", active: true, claude: "s1")]),
        ])
        let cmds = RestorePlan.commands(s, baseIndex: 1)
        XCTAssertTrue(cmds.contains(["send-keys", "-t", "claude-loose-sessions:1",
                                     "cd '/Users/me/a b' && claude --resume s1", "Enter"]), "\(cmds)")
        XCTAssertFalse(cmds.contains { $0.first == "select-pane" })
        XCTAssertFalse(cmds.contains { $0.contains { $0.hasSuffix(":1.0") } })
        // First window's cwd differs from session path, but the resume line cds itself;
        // the extra "cd && clear" still runs first and is harmless.
        XCTAssertEqual(cmds.first, ["send-keys", "-t", "claude-loose-sessions:1",
                                    "cd '/Users/me/a b' && clear", "Enter"])
    }
}
