import Foundation

/// A dotted numeric version like "0.2.2"; accepts an optional "v" prefix
/// (release tags are "vX.Y.Z"). Missing segments compare as 0, so 1.0 == 1.
public struct AppVersion: Comparable {
    public let components: [Int]

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        guard !s.isEmpty else { return nil }
        var nums: [Int] = []
        for part in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(part), n >= 0 else { return nil }
            nums.append(n)
        }
        self.components = nums
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.components.count, rhs.components.count) {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    // Memberwise equality would make [1] != [1, 0]; define it via ordering.
    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
