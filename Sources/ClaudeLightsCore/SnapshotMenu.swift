import Foundation

/// One file in the snapshot folder, as the store found it.
public enum SnapshotListing: Equatable, Sendable {
    case ready(SnapshotFile)
    /// An iCloud placeholder whose download was just requested.
    case downloading(String)
    case unreadable(String)

    public var name: String {
        switch self {
        case .ready(let f): return f.session.name
        case .downloading(let n), .unreadable(let n): return n
        }
    }
}

public struct SnapshotMenuEntry: Equatable, Sendable {
    public let title: String
    /// Snapshot to restore when clicked; nil for "Restore All" and disabled rows.
    public let restoreName: String?
    public let enabled: Bool

    public init(title: String, restoreName: String?, enabled: Bool) {
        self.title = title; self.restoreName = restoreName; self.enabled = enabled
    }
}

public enum SnapshotMenu {
    public static let restoreAllTitle = "Restore All"

    public static func summary(_ file: SnapshotFile, timeZone: TimeZone = .current) -> String {
        let windows = file.session.windows.count
        let claudes = file.session.windows.flatMap(\.panes).filter { $0.claude != nil }.count
        return "\(file.session.name) — \(windows) window\(windows == 1 ? "" : "s"), "
            + "\(claudes) claude · saved \(shortDate(file.savedAt, timeZone: timeZone))"
    }

    public static func restorableNames(_ listings: [SnapshotListing], running: Set<String>) -> [String] {
        listings.compactMap { l -> String? in
            if case .ready(let f) = l, !running.contains(f.session.name) { return f.session.name }
            return nil
        }.sorted()
    }

    public static func entries(_ listings: [SnapshotListing], running: Set<String>,
                               timeZone: TimeZone = .current) -> [SnapshotMenuEntry] {
        guard !listings.isEmpty else {
            return [SnapshotMenuEntry(title: "No saved sessions", restoreName: nil, enabled: false)]
        }
        var out = listings.sorted { $0.name < $1.name }.map { l -> SnapshotMenuEntry in
            switch l {
            case .ready(let f):
                let isRunning = running.contains(f.session.name)
                return SnapshotMenuEntry(
                    title: summary(f, timeZone: timeZone) + (isRunning ? " (running)" : ""),
                    restoreName: isRunning ? nil : f.session.name, enabled: !isRunning)
            case .downloading(let n):
                return SnapshotMenuEntry(title: "\(n) (downloading from iCloud…)",
                                         restoreName: nil, enabled: false)
            case .unreadable(let n):
                return SnapshotMenuEntry(title: "\(n) (unreadable)", restoreName: nil, enabled: false)
            }
        }
        if listings.contains(where: { if case .ready = $0 { return true }; return false }) {
            out.append(SnapshotMenuEntry(
                title: restoreAllTitle, restoreName: nil,
                enabled: !restorableNames(listings, running: running).isEmpty))
        }
        return out
    }

    /// "2026-10-14T09:00:00-07:00" → "10-14 09:00"; unparseable text is shown as-is.
    static func shortDate(_ iso: String, timeZone: TimeZone) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }
}
