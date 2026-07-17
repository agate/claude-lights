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

/// The latest published release: its tag, first .zip asset, and web page.
public struct ReleaseInfo: Equatable {
    public let tag: String
    public let zipURL: String
    public let htmlURL: String

    public init(tag: String, zipURL: String, htmlURL: String) {
        self.tag = tag
        self.zipURL = zipURL
        self.htmlURL = htmlURL
    }
}

public enum ReleaseParser {
    /// Parses a GitHub `releases/latest` response. The zip asset is picked
    /// by extension, never by name, so app/repo renames don't break updates.
    public static func parse(_ json: String) -> ReleaseInfo? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let htmlURL = obj["html_url"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        let zip = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }
        guard let zipURL = zip?["browser_download_url"] as? String else { return nil }
        return ReleaseInfo(tag: tag, zipURL: zipURL, htmlURL: htmlURL)
    }
}
