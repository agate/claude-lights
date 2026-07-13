import XCTest
@testable import ClaudeLightsCore

final class SnapMathTests: XCTestCase {
    // Screen visible area: x 0..1000, y 0..600 (AppKit bottom-left origin)
    let visible = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func testShouldPinWhenTopRightCornerNearScreenCorner() {
        // Bar top-right at (990, 590): 10pt away from corner — within threshold.
        let bar = CGRect(x: 890, y: 560, width: 100, height: 30)
        XCTAssertTrue(SnapMath.shouldPin(barFrame: bar, visible: visible, threshold: 40))
    }

    func testShouldNotPinWhenFarFromCorner() {
        let bar = CGRect(x: 500, y: 300, width: 100, height: 30)
        XCTAssertFalse(SnapMath.shouldPin(barFrame: bar, visible: visible, threshold: 40))
    }

    func testShouldNotPinWhenOnlyOneEdgeIsClose() {
        // Right edge flush but vertically centered.
        let bar = CGRect(x: 900, y: 300, width: 100, height: 30)
        XCTAssertFalse(SnapMath.shouldPin(barFrame: bar, visible: visible, threshold: 40))
    }

    func testPinnedOriginAnchorsTopRight() {
        let origin = SnapMath.pinnedOrigin(barSize: CGSize(width: 120, height: 30),
                                           visible: visible)
        XCTAssertEqual(origin, CGPoint(x: 880, y: 570))
    }

    func testPinnedOriginTracksWidthChanges() {
        // Wider bar: right edge stays at visible.maxX.
        let wide = SnapMath.pinnedOrigin(barSize: CGSize(width: 200, height: 30),
                                         visible: visible)
        XCTAssertEqual(wide.x + 200, visible.maxX)
        XCTAssertEqual(wide.y + 30, visible.maxY)
    }
}
