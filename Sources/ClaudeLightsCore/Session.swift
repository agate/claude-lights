import Foundation

public struct Session: Identifiable, Equatable, Sendable {
    public let id: String
    public let pid: Int
    public let cwd: String
    public let projectName: String
    public let derivedName: String
    public let light: LightState
    public let statusText: String
    public let statusUpdatedAt: Date?
    public let tmuxSession: String?
    public let tmuxWindow: String?
    public let tmuxPane: String?
    public let waitingFor: String?
    /// AI-generated session title from the transcript, if any.
    public let title: String?
    /// True when the session's tmux window is on screen in front of the user.
    public let isOnScreen: Bool
    /// Claude Code version reported by the session's registry record.
    public let version: String?
    /// Session launch time (ms since epoch); the stable sort key.
    public let startedAt: Double?
    /// The claude process's controlling tty (e.g. "/dev/ttys004"). For a bare
    /// terminal session this is the terminal tab's own tty; inside tmux it is
    /// the pane pty (use tmux fields for jumping there instead).
    public let tty: String?

    /// Primary display label: the AI title when available, else the project dir name.
    public var displayName: String { title ?? projectName }

    public init(id: String, pid: Int, cwd: String, projectName: String, derivedName: String,
                light: LightState, statusText: String, statusUpdatedAt: Date?,
                tmuxSession: String?, tmuxWindow: String?, tmuxPane: String? = nil,
                waitingFor: String? = nil, title: String? = nil, isOnScreen: Bool = false,
                version: String? = nil, startedAt: Double? = nil, tty: String? = nil) {
        self.id = id; self.pid = pid; self.cwd = cwd
        self.projectName = projectName; self.derivedName = derivedName
        self.light = light; self.statusText = statusText
        self.statusUpdatedAt = statusUpdatedAt
        self.tmuxSession = tmuxSession; self.tmuxWindow = tmuxWindow
        self.tmuxPane = tmuxPane
        self.waitingFor = waitingFor
        self.title = title; self.isOnScreen = isOnScreen; self.version = version
        self.startedAt = startedAt; self.tty = tty
    }
}

public extension Session {
    /// One-line hover summary shown by the floating bar's custom tooltip.
    /// Idle sessions get an explicit idle duration ("Idle for 12m").
    func summaryLine(now: Date = Date()) -> String {
        var line = "\(displayName) — \(statusText)"
        if let waitingFor { line += " (\(waitingFor))" }
        if light == .green || light == .greenSeen {
            let idle = AgeFormatter.duration(from: statusUpdatedAt, now: now)
            if !idle.isEmpty { line += " for \(idle)" }
        } else {
            let age = AgeFormatter.string(from: statusUpdatedAt, now: now)
            if !age.isEmpty { line += " · \(age)" }
        }
        if tmuxSession == nil { line += " · not in tmux" }
        return line
    }
}

public enum SessionBuilder {
    public static func build(records: [AgentRecord],
                             pidTtys: [Int: String],
                             panes: [TmuxPane],
                             seenIds: Set<String> = [],
                             titles: [String: String] = [:],
                             visibleIds: Set<String> = [],
                             newIds: Set<String> = []) -> [Session] {
        // A session moved to the background keeps a stale interactive record
        // alongside a live bg record under the same sessionId: group them.
        var groups: [String: [AgentRecord]] = [:]
        for record in records where record.kind == "interactive" || record.kind == "bg" {
            guard let id = record.sessionId ?? record.pid.map(String.init) else { continue }
            groups[id, default: []].append(record)
        }
        return groups
            .compactMap { id, group -> Session? in
                // Pure background jobs have no terminal to jump to: hidden.
                guard let anchor = group.first(where: { $0.kind == "interactive" }) else { return nil }
                guard let pid = anchor.pid, let cwd = anchor.cwd else { return nil }
                // The freshest record carries the live status.
                let primary = group.max {
                    ($0.statusUpdatedAt ?? 0) < ($1.statusUpdatedAt ?? 0)
                } ?? anchor
                var light = StateMapper.light(status: primary.status, state: primary.state)
                if light == .green, seenIds.contains(id) { light = .greenSeen }
                // A session with no transcript yet has nothing to report:
                // gray until the first conversation exists.
                if newIds.contains(id) { light = .gray }
                // Any record of the group that maps to a tmux pane provides
                // the jump target (usually the interactive one's tty).
                let pane = group.lazy.compactMap { record in
                    record.pid.flatMap { TmuxMapper.target(forPid: $0, pidTtys: pidTtys, panes: panes) }
                }.first
                return Session(
                    id: id,
                    pid: pid,
                    cwd: cwd,
                    projectName: (cwd as NSString).lastPathComponent,
                    derivedName: anchor.name ?? "",
                    light: light,
                    statusText: newIds.contains(id) ? "Starting" : label(for: light),
                    statusUpdatedAt: primary.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                    tmuxSession: pane?.sessionName,
                    tmuxWindow: pane?.windowIndex,
                    tmuxPane: pane?.paneId,
                    waitingFor: primary.waitingFor,
                    title: titles[id],
                    isOnScreen: visibleIds.contains(id),
                    version: primary.version ?? anchor.version,
                    startedAt: anchor.startedAt,
                    tty: pidTtys[pid])
            }
            // Stable order by launch time (oldest first), so a session keeps
            // its position for the whole of its life — only its color changes
            // as it works/waits/finishes, never its place. Ties break by id.
            .sorted { lhs, rhs in
                let l = lhs.startedAt ?? 0, r = rhs.startedAt ?? 0
                if l != r { return l < r }
                return lhs.id < rhs.id
            }
    }

    public static func label(for light: LightState) -> String {
        switch light {
        case .red: return "Waiting for you"
        case .yellow: return "Working"
        case .greenBg: return "Background running"
        case .green, .greenSeen: return "Idle"
        case .gray: return "Unknown"
        }
    }
}

public enum AgeFormatter {
    public static func string(from date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    /// Bare duration ("12m", "2h") for "Idle for X" phrasing.
    public static func duration(from date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "<1m" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

public enum Aggregate {
    public static func overall(_ sessions: [Session], hasError: Bool) -> LightState {
        if hasError || sessions.isEmpty { return .gray }
        return sessions.map(\.light).min() ?? .gray
    }
}
