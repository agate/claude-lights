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
}
