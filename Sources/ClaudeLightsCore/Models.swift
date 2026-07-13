import Foundation

/// Traffic-light state of a session. Lower sortRank = more urgent.
/// `.green` = idle and not yet looked at; `.greenSeen` = idle and already
/// seen by the user (rendered desaturated).
public enum LightState: String, Comparable, Sendable {
    case red, yellow, green, greenSeen, gray

    public var sortRank: Int {
        switch self {
        case .red: return 0
        case .yellow: return 1
        case .green: return 2
        case .greenSeen: return 3
        case .gray: return 4
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.sortRank < rhs.sortRank }
}
