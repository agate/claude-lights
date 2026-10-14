import Foundation

/// One agent pane reported by `herdr agent list`.
public struct HerdrAgent: Equatable, Sendable {
    /// Workspace-qualified pane id, e.g. "w5:p1"; the `herdr agent focus` target.
    public let paneId: String
    /// Claude Code sessionId herdr detected in the pane (`agent_session.value`).
    public let sessionId: String?
    /// True when this is the pane the herdr UI currently has focused.
    public let isFocused: Bool

    public init(paneId: String, sessionId: String?, isFocused: Bool) {
        self.paneId = paneId; self.sessionId = sessionId; self.isFocused = isFocused
    }
}

/// herdr (a terminal multiplexer for coding agents) runs each pane on its own
/// pty, so a claude inside it has a herdr-owned tty that no terminal tab
/// shows. Its sessionId is reported by herdr, which is the join key; the tab
/// to focus is the one running the herdr client.
public enum HerdrMapper {
    /// Parses `herdr agent list` JSON. Entries without a pane id are dropped;
    /// unparseable output yields [] (herdr absent or not running).
    public static func parseAgents(_ output: String) -> [HerdrAgent] {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let agents = result["agents"] as? [[String: Any]] else { return [] }
        return agents.compactMap { agent in
            guard let paneId = agent["pane_id"] as? String, !paneId.isEmpty else { return nil }
            let session = agent["agent_session"] as? [String: Any]
            return HerdrAgent(paneId: paneId,
                              sessionId: session?["value"] as? String,
                              isFocused: agent["focused"] as? Bool ?? false)
        }
    }

    /// ttys of attached herdr clients from `ps -ax -o tty=,command=`.
    /// A client is a bare `herdr`, `herdr --session <name>` or
    /// `herdr session attach <name>`; the server and one-shot API
    /// subcommands (`herdr agent list`, ...) are not.
    public static func parseClientTtys(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 2, cols[0] != "??",
                  (cols[1] as NSString).lastPathComponent == "herdr" else { return nil }
            let args = Array(cols.dropFirst(2))
            let isClient = args.isEmpty
                || args.first == "--session"
                || (args.count >= 2 && args[0] == "session" && args[1] == "attach")
            return isClient ? "/dev/" + cols[0] : nil
        }
    }
}
