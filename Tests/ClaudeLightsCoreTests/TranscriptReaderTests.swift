import XCTest
@testable import ClaudeLightsCore

final class TranscriptReaderTests: XCTestCase {
    func testTranscriptURLSlug() {
        let url = TranscriptReader.transcriptURL(cwd: "/Users/dev/my.app", sessionId: "abc", home: "/Users/dev")
        XCTAssertEqual(url.path, "/Users/dev/.claude/projects/-Users-dev-my-app/abc.jsonl")
    }

    func testWaitingDescriptionPrefersLastAssistantText() {
        let lines = [
            #"{"type":"user","message":{"content":"hi"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Old answer"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Shall I delete the branch?"}]}}"#,
            #"{"type":"user","message":{"content":"..."}}"#,
        ]
        XCTAssertEqual(TranscriptReader.waitingDescription(fromJSONLines: lines), "Shall I delete the branch?")
    }

    func testWaitingDescriptionToolUseOnly() {
        let lines = [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#,
        ]
        XCTAssertEqual(TranscriptReader.waitingDescription(fromJSONLines: lines), "Wants to run: Bash")
    }

    func testWaitingDescriptionNoneForGarbage() {
        XCTAssertNil(TranscriptReader.waitingDescription(fromJSONLines: ["nope", "{}"]))
        XCTAssertNil(TranscriptReader.waitingDescription(fromJSONLines: []))
    }

    func testTruncateFlattensAndLimits() {
        let long = String(repeating: "a", count: 150) + "\nnext line"
        let out = TranscriptReader.truncate(long, max: 100)
        XCTAssertEqual(out.count, 101) // 100 chars + ellipsis
        XCTAssertFalse(out.contains("\n"))
        XCTAssertEqual(TranscriptReader.truncate("short\ntext", max: 100), "short text")
    }

    func testAiTitleTakesLastOccurrence() {
        let lines = [
            #"{"type":"ai-title","aiTitle":"Old title","sessionId":"de78fb42"}"#,
            #"{"type":"user","message":{"content":"hi"}}"#,
            #"{"type":"ai-title","aiTitle":"Self-learn Swift programming","sessionId":"de78fb42"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}"#,
        ]
        XCTAssertEqual(TranscriptReader.aiTitle(fromJSONLines: lines), "Self-learn Swift programming")
    }

    func testAiTitleNilWhenAbsent() {
        XCTAssertNil(TranscriptReader.aiTitle(fromJSONLines: [#"{"type":"user"}"#, "garbage"]))
        XCTAssertNil(TranscriptReader.aiTitle(fromJSONLines: []))
    }

    func testTailLinesReadsLastLines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cl-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let content = (1...1000).map { #"{"n":\#($0)}"# }.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
        let lines = TranscriptReader.tailLines(of: url, maxBytes: 1024)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertEqual(lines.last, #"{"n":1000}"#)
        XCTAssertLessThan(lines.count, 1000)
    }
}
