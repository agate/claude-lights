import XCTest
@testable import ClaudeLightsCore

final class SessionSummaryTests: XCTestCase {
    func recap(_ content: String, at timestamp: String = "2026-10-15T16:50:23.935Z") -> String {
        let obj: [String: Any] = ["type": "system", "subtype": "away_summary",
                                  "content": content, "timestamp": timestamp]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    func lastPrompt(_ text: String) -> String {
        let obj: [String: Any] = ["type": "last-prompt", "lastPrompt": text, "sessionId": "s"]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    func testRecapWinsAndIsStripped() {
        let lines = [
            recap("Old recap. (disable recaps in /config)", at: "2026-10-14T10:00:00.000Z"),
            recap("Shipped auto-save. Next: release 0.7.0.\n\n[2026-10-15] (disable recaps in /config)"),
            lastPrompt("ship it"),
        ]
        let summary = TranscriptReader.sessionSummary(fromJSONLines: lines)
        XCTAssertEqual(summary?.kind, .recap)
        XCTAssertEqual(summary?.text, "Shipped auto-save. Next: release 0.7.0.")
        XCTAssertEqual(summary?.date, ISO8601DateFormatter.fractional.date(from: "2026-10-15T16:50:23.935Z"))
    }

    func testBacktickDateStampIsStripped() {
        let lines = [recap("Designing a poetry reader.\n\n`2026-10-17` (disable recaps in /config)")]
        XCTAssertEqual(TranscriptReader.sessionSummary(fromJSONLines: lines)?.text,
                       "Designing a poetry reader.")
    }

    func testFallsBackToLastPrompt() {
        let lines = [lastPrompt("first"), "{\"type\":\"user\"}", lastPrompt("fix the font")]
        XCTAssertEqual(TranscriptReader.sessionSummary(fromJSONLines: lines),
                       SessionSummary(kind: .lastPrompt, text: "fix the font", date: nil))
    }

    func testEmptyRecapFallsBackToLastPrompt() {
        let lines = [lastPrompt("hello"), recap("[2026-10-15] (disable recaps in /config)")]
        XCTAssertEqual(TranscriptReader.sessionSummary(fromJSONLines: lines)?.kind, .lastPrompt)
    }

    func testNothingFound() {
        XCTAssertNil(TranscriptReader.sessionSummary(fromJSONLines: ["{\"type\":\"user\"}", "garbage"]))
    }

    func testTailLinesSurvivesInvalidUTF8() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("summary-\(UUID().uuidString).jsonl")
        var data = Data("{\"type\":\"user\",\"bin\":\"".utf8)
        data.append(contentsOf: [0xff, 0xfe, 0xc3])
        data.append(Data("\"}\n\(lastPrompt("still here"))\n".utf8))
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = TranscriptReader.tailLines(of: url)
        XCTAssertEqual(TranscriptReader.sessionSummary(fromJSONLines: lines)?.text, "still here")
    }

    func testWrapSplitsOnSpacesAndCapsLines() {
        XCTAssertEqual(TranscriptReader.wrap("one two three four", width: 9), ["one two", "three", "four"])
        let long = Array(repeating: "word", count: 40).joined(separator: " ")
        let wrapped = TranscriptReader.wrap(long, width: 20, maxLines: 3)
        XCTAssertEqual(wrapped.count, 3)
        XCTAssertTrue(wrapped[2].hasSuffix("…"))
        XCTAssertTrue(wrapped.allSatisfy { $0.count <= 20 })
    }

    func testWrapHardSplitsRunsWithoutSpaces() {
        let cjk = String(repeating: "字", count: 25)
        XCTAssertEqual(TranscriptReader.wrap(cjk, width: 10),
                       [String(repeating: "字", count: 10), String(repeating: "字", count: 10),
                        String(repeating: "字", count: 5)])
    }
}
