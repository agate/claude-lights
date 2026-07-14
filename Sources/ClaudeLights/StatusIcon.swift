import AppKit
import ClaudeLightsCore

/// Status dots encode state twice — a colorblind-safe hue (Okabe-Ito) and a
/// glyph/shape — so no state is distinguishable by color alone.
enum StatusIcon {
    static func color(_ light: LightState) -> NSColor {
        switch light {
        case .red:    return NSColor(srgbRed: 0.835, green: 0.369, blue: 0.000, alpha: 1) // vermillion
        case .yellow: return NSColor(srgbRed: 0.902, green: 0.624, blue: 0.000, alpha: 1) // amber
        case .green:  return NSColor(srgbRed: 0.000, green: 0.620, blue: 0.451, alpha: 1) // bluish green
        case .greenSeen, .gray: return .systemGray
        }
    }

    static func glyph(_ light: LightState) -> String? {
        switch light {
        case .red: return "!"
        case .green: return "✓"
        case .yellow, .greenSeen, .gray: return nil
        }
    }

    /// Third channel for the two calm gray states: a brand-new session is a
    /// hollow ring, an already-seen idle session is a filled disc.
    static func isHollow(_ light: LightState) -> Bool { light == .gray }

    /// Per-glyph optical nudge (points, downward positive). The checkmark
    /// reads a touch high when mass-centered, so it is dropped slightly.
    static func markNudgeDown(_ light: LightState, diameter: CGFloat) -> CGFloat {
        light == .green ? diameter * 0.04 : 0
    }

    /// The white mark drawn on the disc (gear for running, glyph otherwise),
    /// cropped tight to its visible pixels so callers can center it exactly.
    /// The floating bar also rotates this image for the running animation.
    static func mark(for light: LightState, diameter: CGFloat) -> NSImage? {
        if light == .yellow {
            let config = NSImage.SymbolConfiguration(pointSize: diameter * 0.72, weight: .bold)
            guard let gear = NSImage(systemSymbolName: "gearshape.fill",
                                     accessibilityDescription: "running")?
                .withSymbolConfiguration(config) else { return nil }
            // Canvas is doubled so a centroid-centered crop has room to pad
            // symmetrically without being clamped at the edge.
            return tightWhiteMark(canvas: gear.size.width * 2) { rect in
                let g = gear.size
                gear.draw(in: NSRect(x: rect.midX - g.width / 2, y: rect.midY - g.height / 2,
                                     width: g.width, height: g.height))
            }
        }
        guard let glyph = glyph(light) else { return nil }
        let font = NSFont.systemFont(ofSize: diameter * 0.68, weight: .heavy)
        let text = NSAttributedString(string: glyph,
                                      attributes: [.font: font, .foregroundColor: NSColor.white])
        let sz = text.size()
        return tightWhiteMark(canvas: max(sz.width, sz.height) * 2) { rect in
            text.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
        }
    }

    static func image(for light: LightState, diameter: CGFloat = 14,
                      margin: CGFloat = 2, markRotation: CGFloat = 0) -> NSImage {
        let size = NSSize(width: diameter + margin * 2, height: diameter + margin * 2)
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = rect.insetBy(dx: margin, dy: margin)
            if isHollow(light) {
                let path = NSBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
                path.lineWidth = 1.8
                color(light).setStroke()
                path.stroke()
            } else {
                color(light).setFill()
                NSBezierPath(ovalIn: circle).fill()
            }
            if let mark = mark(for: light, diameter: diameter) {
                let m = mark.size
                let nudge = markNudgeDown(light, diameter: diameter) // AppKit y-up: subtract to drop
                if markRotation != 0 {
                    NSGraphicsContext.saveGraphicsState()
                    let t = NSAffineTransform()
                    t.translateX(by: circle.midX, yBy: circle.midY)
                    t.rotate(byDegrees: markRotation)
                    t.concat()
                    mark.draw(in: NSRect(x: -m.width / 2, y: -m.height / 2,
                                         width: m.width, height: m.height))
                    NSGraphicsContext.restoreGraphicsState()
                } else {
                    mark.draw(in: NSRect(x: circle.midX - m.width / 2,
                                         y: circle.midY - m.height / 2 - nudge,
                                         width: m.width, height: m.height))
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Draws a white mark into a supersampled scratch bitmap, crops to its
    /// opaque bounding box, and returns it as a high-resolution image so it
    /// stays crisp on Retina. `canvas`/`draw` work in points; the bitmap is
    /// rendered at `scale`× so measurement and output keep device detail.
    private static func tightWhiteMark(canvas: CGFloat, scale: CGFloat = 3,
                                       _ draw: (NSRect) -> Void) -> NSImage? {
        let pts = ceil(canvas)
        let side = Int(pts * scale)
        guard side > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pts, height: pts) // point size → rep is 'scale'× DPI

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let full = NSRect(x: 0, y: 0, width: pts, height: pts)
        draw(full)
        NSColor.white.set()
        full.fill(using: .sourceAtop) // tint whatever was drawn to solid white
        NSGraphicsContext.restoreGraphicsState()

        // Opaque bounds + centroid in pixels (rep coords are top-left origin).
        var minX = side, minY = side, maxX = -1, maxY = -1
        var sumX = 0, sumY = 0, count = 0
        for y in 0..<side {
            for x in 0..<side where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                sumX += x; sumY += y; count += 1
            }
        }
        guard count > 0, maxX >= minX, maxY >= minY else { return nil }

        // Crop symmetrically about the centroid (center of visual mass), so
        // that centering the returned image optically centers the mark —
        // e.g. a "!" is bar-heavy, and bbox-centering would ride high.
        let cx = Int((Double(sumX) / Double(count)).rounded())
        let cy = Int((Double(sumY) / Double(count)).rounded())
        let hx = max(cx - minX, maxX - cx)
        let hy = max(cy - minY, maxY - cy)
        let cropX = max(0, cx - hx), cropY = max(0, cy - hy)
        let cropW = min(side - cropX, 2 * hx + 1), cropH = min(side - cropY, 2 * hy + 1)
        guard let cg = rep.cgImage?.cropping(to: CGRect(x: cropX, y: cropY,
                                                        width: cropW, height: cropH)) else { return nil }
        // Logical size in points = pixels / scale, so the cropped high-DPI
        // image draws at full resolution.
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cropW) / scale,
                                                 height: CGFloat(cropH) / scale))
    }
}
