import Foundation

public struct TmuxClient: Equatable, Sendable {
    public let tty: String
    public let pid: Int
    public let sessionName: String

    public init(tty: String, pid: Int, sessionName: String) {
        self.tty = tty; self.pid = pid; self.sessionName = sessionName
    }
}

public struct TmuxPane: Equatable, Sendable {
    public let tty: String
    public let sessionName: String
    public let windowIndex: String
    public let paneId: String

    public init(tty: String, sessionName: String, windowIndex: String, paneId: String) {
        self.tty = tty; self.sessionName = sessionName
        self.windowIndex = windowIndex; self.paneId = paneId
    }
}

public enum TmuxMapper {
    /// Format string used with `tmux list-panes -a -F`.
    public static let panesFormat = "#{pane_tty}\t#{session_name}\t#{window_index}\t#{pane_id}"

    public static func parsePanes(_ output: String) -> [TmuxPane] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else { return nil }
            return TmuxPane(tty: parts[0], sessionName: parts[1], windowIndex: parts[2], paneId: parts[3])
        }
    }

    /// Parses `ps -o pid=,tty= -p <pids>`; ttys come back as e.g. "ttys001".
    public static func parsePidTtys(_ output: String) -> [Int: String] {
        var map: [Int: String] = [:]
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2, let pid = Int(cols[0]), cols[1] != "??" else { continue }
            map[pid] = "/dev/" + cols[1]
        }
        return map
    }

    /// Format strings for the visibility check and jump targeting.
    public static let clientsFormat = "#{client_tty}\t#{client_pid}\t#{session_name}"
    public static let windowsFormat = "#{session_name}\t#{window_index}\t#{window_active}"

    /// Parses `tmux list-clients -F '#{client_tty}\t#{client_pid}\t#{session_name}'`.
    public static func parseClients(_ output: String) -> [TmuxClient] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, !parts[0].isEmpty, let pid = Int(parts[1]) else { return nil }
            return TmuxClient(tty: parts[0], pid: pid, sessionName: parts[2])
        }
    }

    /// Returns "session:windowIndex" keys for windows that are the active
    /// window of a tmux session some client is attached to — i.e. windows
    /// the user can currently see in a terminal.
    public static func parseActiveAttachedWindows(attachedSessions: Set<String>,
                                                  windowsOutput: String) -> Set<String> {
        let attached = attachedSessions
        var result = Set<String>()
        for line in windowsOutput.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, parts[2] == "1", attached.contains(parts[0]) else { continue }
            result.insert(parts[0] + ":" + parts[1])
        }
        return result
    }

    /// Shell command that attaches a new terminal window to a tmux session,
    /// with the session name safely single-quoted.
    public static func attachCommand(tmuxPath: String, session: String) -> String {
        let quoted = session.replacingOccurrences(of: "'", with: "'\\''")
        return "\(tmuxPath) attach -t '\(quoted)'"
    }

    public static func target(forPid pid: Int, pidTtys: [Int: String], panes: [TmuxPane]) -> TmuxPane? {
        guard let tty = pidTtys[pid] else { return nil }
        return panes.first { $0.tty == tty }
    }
}
