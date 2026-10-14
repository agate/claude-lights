import Foundation

/// The Claude Code session that was running in a saved pane.
public struct SnapshotClaude: Codable, Equatable, Sendable {
    public var sessionId: String
    public var name: String?
    public var nameSource: String?
    public var cwd: String?
    public var status: String?
    public var version: String?

    public init(sessionId: String, name: String? = nil, nameSource: String? = nil,
                cwd: String? = nil, status: String? = nil, version: String? = nil) {
        self.sessionId = sessionId; self.name = name; self.nameSource = nameSource
        self.cwd = cwd; self.status = status; self.version = version
    }

    private enum CodingKeys: String, CodingKey { case sessionId, name, nameSource, cwd, status, version }

    // Explicit nulls (not omitted keys), matching files the old script wrote.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(name, forKey: .name)
        try c.encode(nameSource, forKey: .nameSource)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(status, forKey: .status)
        try c.encode(version, forKey: .version)
    }
}

public struct SnapshotPane: Codable, Equatable, Sendable {
    public var index: Int
    public var cwd: String
    public var active: Bool
    /// Set when the pane ran a resumable Claude session.
    public var claude: SnapshotClaude?
    /// Foreground command of a non-Claude pane; typed back on restore, not run.
    public var command: String?

    public init(index: Int, cwd: String, active: Bool, claude: SnapshotClaude? = nil,
                command: String? = nil) {
        self.index = index; self.cwd = cwd; self.active = active
        self.claude = claude; self.command = command
    }

    private enum CodingKeys: String, CodingKey { case index, cwd, active, claude, command }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(active, forKey: .active)
        try c.encode(claude, forKey: .claude)
        try c.encode(command, forKey: .command)
    }
}

public struct SnapshotWindow: Codable, Equatable, Sendable {
    public var index: Int
    public var name: String
    public var automaticRename: Bool
    public var layout: String
    public var width: Int
    public var height: Int
    public var active: Bool
    public var zoomed: Bool
    public var panes: [SnapshotPane]

    public init(index: Int, name: String, automaticRename: Bool, layout: String,
                width: Int, height: Int, active: Bool, zoomed: Bool, panes: [SnapshotPane]) {
        self.index = index; self.name = name; self.automaticRename = automaticRename
        self.layout = layout; self.width = width; self.height = height
        self.active = active; self.zoomed = zoomed; self.panes = panes
    }
}

public struct Snapshot: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var windows: [SnapshotWindow]

    public init(name: String, path: String, windows: [SnapshotWindow]) {
        self.name = name; self.path = path; self.windows = windows
    }
}

/// On-disk envelope; `version: 2` is the format the old tmux-claude script used.
public struct SnapshotFile: Codable, Equatable, Sendable {
    public var version: Int
    public var savedAt: String
    public var session: Snapshot

    public init(version: Int = 2, savedAt: String, session: Snapshot) {
        self.version = version; self.savedAt = savedAt; self.session = session
    }
}

public enum SnapshotCodec {
    /// Synthetic snapshot holding every Claude session that ran outside tmux.
    public static let looseName = "claude-loose-sessions"

    /// ASCII-only unreserved set, matching Python's urllib.parse.quote(safe="").
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func encode(_ file: SnapshotFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    public static func decode(_ data: Data) throws -> SnapshotFile {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SnapshotFile.self, from: data)
    }

    public static func fileName(for name: String) -> String {
        (name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name) + ".json"
    }

    /// Session name for a snapshot file, or nil for anything else
    /// (including iCloud placeholders like `.work.json.icloud`).
    public static func sessionName(fromFileName file: String) -> String? {
        guard file.hasSuffix(".json"), !file.hasPrefix(".") else { return nil }
        return String(file.dropLast(5)).removingPercentEncoding
    }

    public static func folderName(computerName: String) -> String {
        computerName.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    /// ISO-8601 with a numeric offset, e.g. "2026-10-14T09:00:00-07:00".
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
