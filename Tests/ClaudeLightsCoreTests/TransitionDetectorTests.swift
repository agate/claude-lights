import XCTest
@testable import ClaudeLightsCore

final class TransitionDetectorTests: XCTestCase {
    func s(_ id: String, _ light: LightState) -> Session {
        Session(id: id, pid: 1, cwd: "/", projectName: "p", derivedName: "",
                light: light, statusText: "", statusUpdatedAt: nil, tmuxSession: nil, tmuxWindow: nil)
    }

    func testFirstSnapshotNeverNotifies() {
        XCTAssertEqual(TransitionDetector.newlyRed(previous: nil, current: [s("a", .red)]), [])
    }

    func testYellowToRedNotifies() {
        let out = TransitionDetector.newlyRed(previous: ["a": .yellow], current: [s("a", .red)])
        XCTAssertEqual(out.map(\.id), ["a"])
    }

    func testStayingRedDoesNotRepeat() {
        XCTAssertEqual(TransitionDetector.newlyRed(previous: ["a": .red], current: [s("a", .red)]), [])
    }

    func testNewSessionAppearingRedNotifies() {
        let out = TransitionDetector.newlyRed(previous: [:], current: [s("b", .red)])
        XCTAssertEqual(out.map(\.id), ["b"])
    }

    func testNonRedNeverNotifies() {
        XCTAssertEqual(TransitionDetector.newlyRed(previous: ["a": .red], current: [s("a", .green)]), [])
    }

    func testWorkFinishedNotifies() {
        let out = TransitionDetector.newlyDone(previous: ["a": .yellow], current: [s("a", .green)])
        XCTAssertEqual(out.map(\.id), ["a"])
        // Red → green (answered elsewhere, then finished) also counts.
        XCTAssertEqual(TransitionDetector.newlyDone(previous: ["a": .red],
                                                    current: [s("a", .greenSeen)]).map(\.id), ["a"])
    }

    func testDoneDoesNotFireForNewOrUnchangedSessions() {
        XCTAssertEqual(TransitionDetector.newlyDone(previous: nil, current: [s("a", .green)]), [])
        XCTAssertEqual(TransitionDetector.newlyDone(previous: [:], current: [s("a", .green)]), [])
        XCTAssertEqual(TransitionDetector.newlyDone(previous: ["a": .green], current: [s("a", .greenSeen)]), [])
        XCTAssertEqual(TransitionDetector.newlyDone(previous: ["a": .gray], current: [s("a", .green)]), [])
        XCTAssertEqual(TransitionDetector.newlyDone(previous: ["a": .yellow], current: [s("a", .red)]), [])
    }
}
