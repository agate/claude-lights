import Foundation
import CoreGraphics

/// Geometry for the floating bar's magnetic top-right corner.
/// All rects use AppKit's bottom-left origin convention.
public enum SnapMath {
    /// True when the bar's top-right corner is within `threshold` points of
    /// the visible area's top-right corner (both axes must be close).
    public static func shouldPin(barFrame: CGRect, visible: CGRect,
                                 threshold: CGFloat) -> Bool {
        abs(visible.maxX - barFrame.maxX) <= threshold &&
        abs(visible.maxY - barFrame.maxY) <= threshold
    }

    /// Origin that keeps the bar's right and top edges flush with the
    /// visible area's right and top edges.
    public static func pinnedOrigin(barSize: CGSize, visible: CGRect) -> CGPoint {
        CGPoint(x: visible.maxX - barSize.width,
                y: visible.maxY - barSize.height)
    }

    /// Screen-independent position: origin expressed as a 0...1 fraction of
    /// the space available for the bar on this screen.
    public static func fraction(origin: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
        let availX = visible.width - size.width
        let availY = visible.height - size.height
        func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
        return CGPoint(x: availX > 0 ? clamp((origin.x - visible.minX) / availX) : 0,
                       y: availY > 0 ? clamp((origin.y - visible.minY) / availY) : 0)
    }

    /// Inverse of `fraction(origin:size:visible:)` for any target screen.
    public static func origin(fraction: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
        let availX = max(visible.width - size.width, 0)
        let availY = max(visible.height - size.height, 0)
        return CGPoint(x: visible.minX + availX * fraction.x,
                       y: visible.minY + availY * fraction.y)
    }
}
