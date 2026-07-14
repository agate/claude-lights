import XCTest
@testable import ClaudeLightsCore

final class SupportedVersionTests: XCTestCase {
    func testMeetsMinimum() {
        XCTAssertTrue(SupportedVersion.isSupported("2.1.207"))
        XCTAssertTrue(SupportedVersion.isSupported("2.1.209"))
        XCTAssertTrue(SupportedVersion.isSupported("2.2.0"))
        XCTAssertTrue(SupportedVersion.isSupported("3.0.0"))
    }

    func testBelowMinimum() {
        XCTAssertFalse(SupportedVersion.isSupported("2.1.206"))
        XCTAssertFalse(SupportedVersion.isSupported("2.1.0"))
        XCTAssertFalse(SupportedVersion.isSupported("2.0.999"))
        XCTAssertFalse(SupportedVersion.isSupported("1.9.9"))
    }

    func testHandlesSuffixesAndJunk() {
        XCTAssertTrue(SupportedVersion.isSupported("2.1.207 (Claude Code)"))
        XCTAssertTrue(SupportedVersion.isSupported("2.1.210-beta"))
        // Unknown / unparseable version is treated as supported (no false alarms).
        XCTAssertTrue(SupportedVersion.isSupported(nil))
        XCTAssertTrue(SupportedVersion.isSupported(""))
        XCTAssertTrue(SupportedVersion.isSupported("garbage"))
    }

    func testShortComponents() {
        XCTAssertTrue(SupportedVersion.isSupported("2.2"))   // 2.2 >= 2.1.207
        XCTAssertFalse(SupportedVersion.isSupported("2.1"))  // 2.1 == 2.1.0 < 2.1.207
    }
}
