import XCTest
@testable import ClaudeLightsCore

final class StateMapperTests: XCTestCase {
    func testLightStateOrdering() {
        XCTAssertLessThan(LightState.red, LightState.yellow)
        XCTAssertLessThan(LightState.yellow, LightState.greenBg)
        XCTAssertLessThan(LightState.greenBg, LightState.green)
        XCTAssertLessThan(LightState.green, LightState.greenSeen)
        XCTAssertLessThan(LightState.greenSeen, LightState.gray)
    }

    func testBusyIsYellow() {
        XCTAssertEqual(StateMapper.light(status: "busy", state: nil), .yellow)
    }

    func testShellIsGreenBg() {
        // Verified live on 2.1.212: "shell" means the main thread is quiet
        // but a background task is still running (foreground commands report
        // "busy"). Older versions (2.1.209) also reported "shell" during
        // foreground commands — those briefly show greenBg instead of yellow.
        XCTAssertEqual(StateMapper.light(status: "shell", state: nil), .greenBg)
    }

    func testIdleIsGreen() {
        XCTAssertEqual(StateMapper.light(status: "idle", state: nil), .green)
    }

    func testIdleWithDoneStateIsGreen() {
        XCTAssertEqual(StateMapper.light(status: "idle", state: "done"), .green)
    }

    func testWaitingVariantsAreRed() {
        // Exact waiting value unverified at design time; match defensively.
        XCTAssertEqual(StateMapper.light(status: "waiting", state: nil), .red)
        XCTAssertEqual(StateMapper.light(status: "waiting_input", state: nil), .red)
        XCTAssertEqual(StateMapper.light(status: "needs_permission", state: nil), .red)
        XCTAssertEqual(StateMapper.light(status: "blocked", state: nil), .red)
        XCTAssertEqual(StateMapper.light(status: "needs_attention", state: nil), .red)
    }

    func testUnknownIsGray() {
        XCTAssertEqual(StateMapper.light(status: nil, state: nil), .gray)
        XCTAssertEqual(StateMapper.light(status: "banana", state: nil), .gray)
    }
}
