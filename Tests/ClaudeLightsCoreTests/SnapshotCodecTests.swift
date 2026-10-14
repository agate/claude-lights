import XCTest
@testable import ClaudeLightsCore

final class SnapshotCodecTests: XCTestCase {
    /// Written by the retired ~/bin/tmux-claude script (version 2).
    let scriptFixture = """
    {
      "version": 2,
      "saved_at": "2026-10-13T18:00:00-07:00",
      "session": {
        "name": "work",
        "path": "/Users/me/src",
        "windows": [
          {
            "index": 1, "name": "api", "automatic_rename": false,
            "layout": "b25f,200x50,0,0{100x50,0,0,1,99x50,101,0,2}",
            "width": 200, "height": 50, "active": true, "zoomed": false,
            "panes": [
              {"index": 0, "cwd": "/Users/me/src/api", "active": true,
               "claude": {"session_id": "abc", "name": "api-fix", "name_source": "auto",
                          "cwd": "/Users/me/src/api", "status": "idle", "version": "2.1.212"},
               "command": null},
              {"index": 1, "cwd": "/Users/me/src/api", "active": false,
               "claude": null, "command": "npm run dev"}
            ]
          }
        ]
      }
    }
    """

    func testDecodesScriptFile() throws {
        let file = try SnapshotCodec.decode(Data(scriptFixture.utf8))
        XCTAssertEqual(file.version, 2)
        XCTAssertEqual(file.savedAt, "2026-10-13T18:00:00-07:00")
        XCTAssertEqual(file.session.name, "work")
        let w = file.session.windows[0]
        XCTAssertFalse(w.automaticRename)
        XCTAssertEqual(w.panes[0].claude?.sessionId, "abc")
        XCTAssertEqual(w.panes[0].claude?.nameSource, "auto")
        XCTAssertNil(w.panes[1].claude)
        XCTAssertEqual(w.panes[1].command, "npm run dev")
    }

    func testRoundTripAndExplicitNulls() throws {
        let file = try SnapshotCodec.decode(Data(scriptFixture.utf8))
        let data = try SnapshotCodec.encode(file)
        XCTAssertEqual(try SnapshotCodec.decode(data), file)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"claude\" : null"), text)
        XCTAssertTrue(text.contains("\"command\" : null"), text)
        XCTAssertTrue(text.contains("\"saved_at\""), text)
        XCTAssertTrue(text.contains("\"session_id\""), text)
    }

    func testFileNameIsPercentEncodedAndReversible() {
        XCTAssertEqual(SnapshotCodec.fileName(for: "my work/x"), "my%20work%2Fx.json")
        XCTAssertEqual(SnapshotCodec.sessionName(fromFileName: "my%20work%2Fx.json"), "my work/x")
        XCTAssertNil(SnapshotCodec.sessionName(fromFileName: "notes.txt"))
        XCTAssertNil(SnapshotCodec.sessionName(fromFileName: ".work.json.icloud"))
    }

    func testNonASCIINameIsPercentEncodedLikeTheOldScript() {
        // Matches Python's urllib.parse.quote(name, safe="") used by the old script.
        XCTAssertEqual(SnapshotCodec.fileName(for: "工作"), "%E5%B7%A5%E4%BD%9C.json")
        XCTAssertEqual(SnapshotCodec.sessionName(fromFileName: "%E5%B7%A5%E4%BD%9C.json"), "工作")
        XCTAssertEqual(SnapshotCodec.looseName, "claude-loose-sessions")
    }

    func testFolderNameSanitizesSeparators() {
        XCTAssertEqual(SnapshotCodec.folderName(computerName: "Hao's Mac/Pro:2"), "Hao's Mac-Pro-2")
    }

    func testTimestampHasOffset() {
        let date = Date(timeIntervalSince1970: 1_760_403_600) // 2025-10-14T01:00:00Z
        let tz = TimeZone(secondsFromGMT: -7 * 3600)!
        XCTAssertEqual(SnapshotCodec.timestamp(date, timeZone: tz), "2025-10-13T18:00:00-07:00")
    }
}
