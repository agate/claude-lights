import XCTest
@testable import ClaudeLightsCore

final class SeenTrackerTests: XCTestCase {
    func testVisibleGreenBecomesSeen() {
        let next = SeenTracker.update(seen: [], greens: ["a"], visible: ["a"], all: ["a"])
        XCTAssertEqual(next, ["a"])
    }

    func testInvisibleGreenStaysUnseen() {
        let next = SeenTracker.update(seen: [], greens: ["a"], visible: [], all: ["a"])
        XCTAssertEqual(next, [])
    }

    func testSeenPersistsWhileGreen() {
        let next = SeenTracker.update(seen: ["a"], greens: ["a"], visible: [], all: ["a"])
        XCTAssertEqual(next, ["a"])
    }

    func testLeavingGreenResetsSeen() {
        // Session went busy again: next time it turns green it is unseen.
        let next = SeenTracker.update(seen: ["a"], greens: [], visible: [], all: ["a"])
        XCTAssertEqual(next, [])
    }

    func testGoneSessionsArePruned() {
        let next = SeenTracker.update(seen: ["a", "b"], greens: ["a"], visible: [], all: ["a"])
        XCTAssertEqual(next, ["a"])
    }

    func testVisibleNonGreenNotMarked() {
        let next = SeenTracker.update(seen: [], greens: [], visible: ["a"], all: ["a"])
        XCTAssertEqual(next, [])
    }
}
