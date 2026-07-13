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
}
