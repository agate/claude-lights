import Foundation

/// tmux `-F` formats and parsers for capturing a snapshot.
public enum SnapshotTmux {
    private static let sep = TmuxMapper.sep

    public struct SessionRow: Equatable, Sendable {
        public let name: String; public let path: String
        public init(name: String, path: String) { self.name = name; self.path = path }
    }

    public struct WindowRow: Equatable, Sendable {
        public let session: String; public let index: Int; public let name: String
        public let layout: String; public let active: Bool; public let zoomed: Bool
        public let width: Int; public let height: Int; public let automaticRename: Bool
        public init(session: String, index: Int, name: String, layout: String, active: Bool,
                    zoomed: Bool, width: Int, height: Int, automaticRename: Bool) {
            self.session = session; self.index = index; self.name = name; self.layout = layout
            self.active = active; self.zoomed = zoomed; self.width = width; self.height = height
            self.automaticRename = automaticRename
        }
    }

    public struct PaneRow: Equatable, Sendable {
        public let session: String; public let windowIndex: Int; public let index: Int
        public let paneId: String; public let pid: Int; public let cwd: String
        public let active: Bool
        public init(session: String, windowIndex: Int, index: Int, paneId: String, pid: Int,
                    cwd: String, active: Bool) {
            self.session = session; self.windowIndex = windowIndex; self.index = index
            self.paneId = paneId; self.pid = pid; self.cwd = cwd; self.active = active
        }
    }

    /// `tmux list-sessions -F`
    public static let sessionsFormat = "#{session_name}\(sep)#{session_path}"
    /// `tmux list-windows -a -F`. `#{automatic-rename}` is the effective option value.
    public static let windowsFormat = [
        "#{session_name}", "#{window_index}", "#{window_name}", "#{window_layout}",
        "#{window_active}", "#{window_zoomed_flag}", "#{window_width}", "#{window_height}",
        "#{automatic-rename}",
    ].joined(separator: sep)
    /// `tmux list-panes -a -F`
    public static let panesFormat = [
        "#{session_name}", "#{window_index}", "#{pane_index}", "#{pane_id}", "#{pane_pid}",
        "#{pane_current_path}", "#{pane_active}",
    ].joined(separator: sep)

    private static func rows(_ output: String, count: Int) -> [[String]] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: sep)
            return parts.count == count ? parts : nil
        }
    }

    public static func parseSessions(_ output: String) -> [SessionRow] {
        rows(output, count: 2).map { SessionRow(name: $0[0], path: $0[1]) }
    }

    public static func parseWindows(_ output: String) -> [WindowRow] {
        rows(output, count: 9).compactMap { f in
            guard let index = Int(f[1]), let w = Int(f[6]), let h = Int(f[7]) else { return nil }
            // Empty means the option is unset, which tmux treats as on.
            return WindowRow(session: f[0], index: index, name: f[2], layout: f[3],
                             active: f[4] == "1", zoomed: f[5] == "1", width: w, height: h,
                             automaticRename: f[8] != "off" && f[8] != "0")
        }
    }

    public static func parsePanes(_ output: String) -> [PaneRow] {
        rows(output, count: 7).compactMap { f in
            guard let w = Int(f[1]), let i = Int(f[2]), let pid = Int(f[4]) else { return nil }
            return PaneRow(session: f[0], windowIndex: w, index: i, paneId: f[3], pid: pid,
                           cwd: f[5], active: f[6] == "1")
        }
    }
}

public enum SnapshotBuilder {
    /// Default size for windows of the loose snapshot (they have no tmux size yet).
    static let looseSize = (width: 200, height: 50)

    /// SessionBuilder falls back to the pid as id when the registry has no
    /// sessionId; such a session cannot be resumed.
    public static func isResumable(_ s: Session) -> Bool { s.id != String(s.pid) }

    static func claude(for s: Session) -> SnapshotClaude {
        SnapshotClaude(sessionId: s.id, name: s.derivedName.isEmpty ? s.title : s.derivedName,
                       nameSource: nil, cwd: s.cwd, status: s.statusText, version: s.version)
    }

    /// One snapshot per running tmux session, plus the loose snapshot for
    /// resumable Claude sessions outside tmux and herdr. When a tmux session named
    /// `claude-loose-sessions` is already running, loose windows are
    /// appended to it instead of producing a second snapshot of that name.
    public static func all(tmuxSessions: [SnapshotTmux.SessionRow],
                           windows: [SnapshotTmux.WindowRow],
                           panes: [SnapshotTmux.PaneRow],
                           sessions: [Session],
                           procs: ProcessTable,
                           home: String,
                           baseIndex: Int) -> [Snapshot] {
        let byPane = Dictionary(
            sessions.compactMap { s in s.tmuxPane.map { ($0, s) } }.filter { isResumable($0.1) },
            uniquingKeysWith: { first, _ in first })
        var snaps = tmuxSessions.map { row -> Snapshot in
            let ws = windows.filter { $0.session == row.name }.sorted { $0.index < $1.index }.map { w in
                let ps = panes.filter { $0.session == row.name && $0.windowIndex == w.index }
                    .sorted { $0.index < $1.index }
                    .map { p -> SnapshotPane in
                        if let s = byPane[p.paneId] {
                            return SnapshotPane(index: p.index, cwd: p.cwd, active: p.active,
                                                claude: claude(for: s))
                        }
                        return SnapshotPane(index: p.index, cwd: p.cwd, active: p.active,
                                            command: procs.foregroundCommand(shellPid: p.pid))
                    }
                return SnapshotWindow(index: w.index, name: w.name, automaticRename: w.automaticRename,
                                      layout: w.layout, width: w.width, height: w.height,
                                      active: w.active, zoomed: w.zoomed, panes: ps)
            }
            return Snapshot(name: row.name, path: row.path, windows: ws)
        }

        // herdr sessions are skipped: herdr restores its panes and resumes
        // their claude sessions itself, so saving them would duplicate each.
        // herdrPane needs herdr to report the sessionId; the process tree
        // catches the rest.
        let loose = sessions.filter { s in
            s.tmuxSession == nil && s.herdrPane == nil && isResumable(s)
                && !procs.hasAncestor(of: s.pid, where: HerdrMapper.isServerCommand)
        }
            .sorted { ($0.startedAt ?? 0, $0.id) < ($1.startedAt ?? 0, $1.id) }
        guard !loose.isEmpty else { return snaps }
        if let i = snaps.firstIndex(where: { $0.name == SnapshotCodec.looseName }) {
            let next = (snaps[i].windows.map(\.index).max() ?? (baseIndex - 1)) + 1
            snaps[i].windows += looseWindows(loose, firstIndex: next, firstActive: false)
        } else {
            snaps.append(Snapshot(name: SnapshotCodec.looseName, path: home,
                                  windows: looseWindows(loose, firstIndex: baseIndex,
                                                        firstActive: true)))
        }
        return snaps
    }

    static func looseWindows(_ sessions: [Session], firstIndex: Int,
                             firstActive: Bool) -> [SnapshotWindow] {
        sessions.enumerated().map { i, s in
            SnapshotWindow(index: firstIndex + i, name: s.displayName, automaticRename: false,
                           layout: "", width: looseSize.width, height: looseSize.height,
                           active: firstActive && i == 0, zoomed: false,
                           panes: [SnapshotPane(index: 0, cwd: s.cwd, active: true,
                                                claude: claude(for: s))])
        }
    }
}
