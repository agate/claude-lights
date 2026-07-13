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

    func testFractionRoundTrip() {
        let size = CGSize(width: 100, height: 30)
        let origin = CGPoint(x: 450, y: 285) // center of available space
        let f = SnapMath.fraction(origin: origin, size: size, visible: visible)
        XCTAssertEqual(f.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(f.y, 0.5, accuracy: 0.001)
        let back = SnapMath.origin(fraction: f, size: size, visible: visible)
        XCTAssertEqual(back, origin)
    }

    func testFractionAppliesToDifferentScreen() {
        let size = CGSize(width: 100, height: 30)
        // Top-right-ish on the first screen…
        let f = SnapMath.fraction(origin: CGPoint(x: 900, y: 570), size: size, visible: visible)
        // …lands top-right-ish on a screen with other bounds and offset.
        let other = CGRect(x: 2000, y: 100, width: 500, height: 400)
        let origin = SnapMath.origin(fraction: f, size: size, visible: other)
        XCTAssertEqual(origin, CGPoint(x: 2400, y: 470))
    }

    func testFractionClampsOutOfBounds() {
        let size = CGSize(width: 100, height: 30)
        let f = SnapMath.fraction(origin: CGPoint(x: 5000, y: -50), size: size, visible: visible)
        XCTAssertEqual(f, CGPoint(x: 1, y: 0))
        // Bar wider than the screen: degenerate space maps to 0 / origin edge.
        let tiny = CGRect(x: 0, y: 0, width: 80, height: 20)
        XCTAssertEqual(SnapMath.fraction(origin: .zero, size: size, visible: tiny), .zero)
        XCTAssertEqual(SnapMath.origin(fraction: CGPoint(x: 0.5, y: 0.5), size: size, visible: tiny),
                       CGPoint(x: 0, y: 0))
    }

    func testPinnedOriginTracksWidthChanges() {
        // Wider bar: right edge stays at visible.maxX.
        let wide = SnapMath.pinnedOrigin(barSize: CGSize(width: 200, height: 30),
                                         visible: visible)
        XCTAssertEqual(wide.x + 200, visible.maxX)
        XCTAssertEqual(wide.y + 30, visible.maxY)
    }
}
