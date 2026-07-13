import AppKit
import ClaudeLightsCore

enum StatusIcon {
    static func color(_ light: LightState) -> NSColor {
        switch light {
        case .red: return .systemRed
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .greenSeen:
            return NSColor.systemGreen.blended(withFraction: 0.65, of: .systemGray) ?? .systemGray
        case .gray: return .systemGray
        }
    }

    static func image(for light: LightState, diameter: CGFloat = 10) -> NSImage {
        let size = NSSize(width: diameter + 4, height: diameter + 4)
        let image = NSImage(size: size, flipped: false) { rect in
            color(light).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
