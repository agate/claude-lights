import Foundation

/// One Claude Code session as reported by ~/.claude/sessions/<pid>.json
/// (same schema `claude agents --json` serves). All fields optional so a
/// schema drift never crashes us — missing data degrades to gray.
public struct AgentRecord: Decodable, Equatable, Sendable {
    public var pid: Int?
    public var cwd: String?
    public var kind: String?
    public var sessionId: String?
    public var name: String?
    public var status: String?
    public var state: String?
    public var startedAt: Double?
    public var statusUpdatedAt: Double?
    /// Human-readable wait reason, e.g. "permission prompt" (verified live on 2.1.207).
    public var waitingFor: String?

    public init(pid: Int? = nil, cwd: String? = nil, kind: String? = nil,
                sessionId: String? = nil, name: String? = nil, status: String? = nil,
                state: String? = nil, startedAt: Double? = nil, statusUpdatedAt: Double? = nil,
                waitingFor: String? = nil) {
        self.pid = pid; self.cwd = cwd; self.kind = kind
        self.sessionId = sessionId; self.name = name; self.status = status
        self.state = state; self.startedAt = startedAt; self.statusUpdatedAt = statusUpdatedAt
        self.waitingFor = waitingFor
    }

    private enum CodingKeys: String, CodingKey {
        case pid, cwd, kind, sessionId, name, status, state, startedAt, statusUpdatedAt, waitingFor
    }

    public static func parseOne(_ json: String) -> AgentRecord? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentRecord.self, from: data)
    }

    public static func parseList(_ json: String) -> [AgentRecord] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([AgentRecord].self, from: data)) ?? []
    }
}

public enum SessionRegistry {
    public static var defaultDir: URL {
        // Override hook for demos and testing.
        if let override = ProcessInfo.processInfo.environment["CLAUDE_LIGHTS_SESSIONS_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")
    }

    /// Loads all live session records. Stale files of dead processes are skipped.
    public static func load(dir: URL = defaultDir,
                            isAlive: (Int) -> Bool = { kill(pid_t($0), 0) == 0 }) -> [AgentRecord] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> AgentRecord? in
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let record = AgentRecord.parseOne(text),
                      let pid = record.pid, isAlive(pid) else { return nil }
                return record
            }
    }
}
