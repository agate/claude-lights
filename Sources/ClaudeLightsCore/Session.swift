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

    /// Primary display label: the AI title when available, else the project dir name.
    public var displayName: String { title ?? projectName }

    public init(id: String, pid: Int, cwd: String, projectName: String, derivedName: String,
                light: LightState, statusText: String, statusUpdatedAt: Date?,
                tmuxSession: String?, tmuxWindow: String?, tmuxPane: String? = nil,
                waitingFor: String? = nil, title: String? = nil, isOnScreen: Bool = false) {
        self.id = id; self.pid = pid; self.cwd = cwd
        self.projectName = projectName; self.derivedName = derivedName
        self.light = light; self.statusText = statusText
        self.statusUpdatedAt = statusUpdatedAt
        self.tmuxSession = tmuxSession; self.tmuxWindow = tmuxWindow
        self.tmuxPane = tmuxPane
        self.waitingFor = waitingFor
        self.title = title; self.isOnScreen = isOnScreen
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
                             visibleIds: Set<String> = []) -> [Session] {
        records
            .filter { $0.kind == "interactive" }
            .compactMap { record -> Session? in
                guard let pid = record.pid, let cwd = record.cwd else { return nil }
                let id = record.sessionId ?? String(pid)
                var light = StateMapper.light(status: record.status, state: record.state)
                if light == .green, seenIds.contains(id) { light = .greenSeen }
                let pane = TmuxMapper.target(forPid: pid, pidTtys: pidTtys, panes: panes)
                return Session(
                    id: id,
                    pid: pid,
                    cwd: cwd,
                    projectName: (cwd as NSString).lastPathComponent,
                    derivedName: record.name ?? "",
                    light: light,
                    statusText: label(for: light),
                    statusUpdatedAt: record.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                    tmuxSession: pane?.sessionName,
                    tmuxWindow: pane?.windowIndex,
                    tmuxPane: pane?.paneId,
                    waitingFor: record.waitingFor,
                    title: titles[id],
                    isOnScreen: visibleIds.contains(id))
            }
            .sorted { lhs, rhs in
                if lhs.light != rhs.light { return lhs.light < rhs.light }
                return lhs.projectName.localizedCompare(rhs.projectName) == .orderedAscending
            }
    }

    public static func label(for light: LightState) -> String {
        switch light {
        case .red: return "Waiting for you"
        case .yellow: return "Working"
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
