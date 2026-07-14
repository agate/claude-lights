import Foundation

/// Minimum Claude Code version whose session registry reports the fields the
/// app depends on — most importantly the `waiting` status (drives the red
/// "needs you" light) and the `waitingFor` reason string. Older versions
/// only report busy/idle, so a session awaiting your input would never turn
/// red. See the design spec's data-source notes.
public enum SupportedVersion {
    public static let minimum = "2.1.207"

    /// True when `version` is at least `minimum`. An absent or unparseable
    /// version is treated as supported, so we never nag on missing data.
    public static func isSupported(_ version: String?) -> Bool {
        guard let parsed = components(version) else { return true }
        return parsed.lexicographicallyPrecedes(components(minimum)!) == false
    }

    /// Leading dotted numeric components, e.g. "2.1.207 (Claude Code)" → [2,1,207].
    /// Pads to 3 components so "2.2" compares as [2,2,0].
    private static func components(_ version: String?) -> [Int]? {
        guard let version else { return nil }
        let head = version.prefix { $0.isNumber || $0 == "." }
        let parts = head.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        return parts + Array(repeating: 0, count: max(0, 3 - parts.count))
    }
}
