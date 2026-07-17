import XCTest
@testable import ClaudeLightsCore

final class UpdateCheckTests: XCTestCase {
    // MARK: AppVersion

    func testParsePlain() {
        XCTAssertEqual(AppVersion("0.2.2")?.components, [0, 2, 2])
    }

    func testParseVPrefix() {
        XCTAssertEqual(AppVersion("v0.3.0")?.components, [0, 3, 0])
    }

    func testParseGarbage() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("abc"))
        XCTAssertNil(AppVersion("1.2.beta"))
        XCTAssertNil(AppVersion("v"))
    }

    func testCompareBasic() {
        XCTAssertTrue(AppVersion("0.2.2")! < AppVersion("0.3.0")!)
        XCTAssertTrue(AppVersion("0.9.9")! < AppVersion("1.0.0")!)
        XCTAssertFalse(AppVersion("0.3.0")! < AppVersion("0.2.2")!)
    }

    func testCompareDifferentLengths() {
        // "1.0" == "1" semantically; neither is less.
        XCTAssertFalse(AppVersion("1.0")! < AppVersion("1")!)
        XCTAssertFalse(AppVersion("1")! < AppVersion("1.0")!)
        XCTAssertEqual(AppVersion("1.0")!, AppVersion("1")!)
        XCTAssertTrue(AppVersion("1")! < AppVersion("1.0.1")!)
    }
}
