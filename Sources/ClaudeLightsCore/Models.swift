import Foundation

/// Traffic-light state of a session. Lower sortRank = more urgent.
/// `.green` = idle and not yet looked at; `.greenSeen` = idle and already
/// seen by the user (rendered desaturated).
/// `.greenBg` = the main thread answered but a background task still runs
/// (registry status "shell"): green disc with a static gear. Whether that
/// task feeds a follow-up answer or is a long-lived server is the user's
/// knowledge, not the registry's — the light just reports both facts.
public enum LightState: String, Comparable, Sendable {
    case red, yellow, greenBg, green, greenSeen, gray

    public var sortRank: Int {
        switch self {
        case .red: return 0
        case .yellow: return 1
        case .greenBg: return 2
        case .green: return 3
        case .greenSeen: return 4
        case .gray: return 5
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.sortRank < rhs.sortRank }
}
