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

    /// Second encoding channel: a text glyph for the attention states.
    /// Running uses a gear symbol instead (see `gearImage`).
    static func glyph(_ light: LightState) -> String? {
        switch light {
        case .red: return "!"
        case .green: return "✓"
        case .yellow, .greenSeen, .gray: return nil
        }
    }

    /// White gear symbol for the running state (static here; the floating
    /// bar spins it). SF Symbols; nil on the rare system without it.
    static func gearImage(diameter: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: diameter * 0.72, weight: .bold)
        return NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "running")?
            .withSymbolConfiguration(config)
    }

    /// Third channel for the two calm gray states: a brand-new session is a
    /// hollow ring, an already-seen idle session is a filled disc.
    static func isHollow(_ light: LightState) -> Bool { light == .gray }

    static func image(for light: LightState, diameter: CGFloat = 14) -> NSImage {
        let size = NSSize(width: diameter + 4, height: diameter + 4)
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = rect.insetBy(dx: 2, dy: 2)
            if isHollow(light) {
                let path = NSBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
                path.lineWidth = 1.8
                color(light).setStroke()
                path.stroke()
            } else {
                color(light).setFill()
                NSBezierPath(ovalIn: circle).fill()
            }
            if light == .yellow, let gear = gearImage(diameter: diameter) {
                let g = gear.size
                let box = NSRect(x: circle.midX - g.width / 2, y: circle.midY - g.height / 2,
                                 width: g.width, height: g.height)
                gear.draw(in: box)
                NSColor.white.set()
                box.fill(using: .sourceAtop) // tint the template gear white
            } else if let glyph = glyph(light) {
                let font = NSFont.systemFont(ofSize: diameter * 0.64, weight: .heavy)
                let text = NSAttributedString(string: glyph, attributes: [
                    .font: font, .foregroundColor: NSColor.white,
                ])
                let bounds = text.size()
                text.draw(at: NSPoint(x: circle.midX - bounds.width / 2,
                                      y: circle.midY - bounds.height / 2))
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
