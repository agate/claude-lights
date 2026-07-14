import Foundation
import ClaudeLightsCore

final class Poller {
    var onSnapshot: (([Session], String?) -> Void)?
    var onNewlyRed: (([Session]) -> Void)?
    var onNewlyDone: (([Session]) -> Void)?
    /// Injected by the app: whether a known terminal app is frontmost.
    var isTerminalFrontmost: () -> Bool = { true }

    private let tmuxPath = BinaryLocator.locate("tmux")
    private let queue = DispatchQueue(label: "me.honghao.claudelights.poller")
    private var timer: DispatchSourceTimer?
    private var watcher: RegistryWatcher?
    private var previous: [String: LightState]?
    // Demo/testing hook: pre-seed the seen set so dimmed green is showable.
    private var seen: Set<String> = Set(
        (ProcessInfo.processInfo.environment["CLAUDE_LIGHTS_DEMO_SEEN_IDS"] ?? "")
            .split(separator: ",").map(String.init))
    private var titles: [String: String] = [:]
    private var titleScanned: Set<String> = []

    /// Marks a session as looked-at (user jumped to it) and refreshes.
    func markSeen(_ id: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.seen.insert(id)
            self.poll()
        }
    }

    /// Hybrid scheduling: FSEvents on the registry directory delivers status
    /// changes near-instantly; the slow timer covers everything that has no
    /// file to watch (tmux visibility sampling, screen following, pid
    /// liveness, age text refresh).
    func start(interval: TimeInterval = 10.0) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t

        watcher = RegistryWatcher(directory: SessionRegistry.defaultDir) { [weak self] in
            self?.poll()
        }
        watcher?.start(on: queue)
    }

    /// Keeps the sessionId → AI title cache fresh. First sight of a session
    /// scans a large tail of its transcript; afterwards only a small tail is
    /// checked (a title update appends a new ai-title line, so it is always
    /// near the end when it changes).
    private func refreshTitles(records: [AgentRecord], all: Set<String>) {
        for record in records where record.kind == "interactive" {
            guard let cwd = record.cwd, let id = record.sessionId else { continue }
            let url = TranscriptReader.transcriptURL(cwd: cwd, sessionId: id)
            let maxBytes = titleScanned.contains(id) ? 128 * 1024 : 8 * 1024 * 1024
            titleScanned.insert(id)
            if let title = TranscriptReader.aiTitle(fromJSONLines:
                TranscriptReader.tailLines(of: url, maxBytes: maxBytes)) {
                titles[id] = title
            }
        }
        titles = titles.filter { all.contains($0.key) }
        titleScanned.formIntersection(all)
    }

    private func poll() {
        var error: String?
        if !FileManager.default.fileExists(atPath: SessionRegistry.defaultDir.path) {
            error = "Claude Code session registry not found (~/.claude/sessions)"
        }
        let records = SessionRegistry.load()

        let pids = records.compactMap {
            $0.kind == "interactive" || $0.kind == "bg" ? $0.pid : nil
        }
        var pidTtys: [Int: String] = [:]
        if !pids.isEmpty,
           let psOut = Shell.run("/bin/ps", ["-o", "pid=,tty=", "-p",
                                             pids.map(String.init).joined(separator: ",")]) {
            pidTtys = TmuxMapper.parsePidTtys(psOut)
        }

        var panes: [TmuxPane] = []
        if let tmuxPath,
           let panesOut = Shell.run(tmuxPath, ["list-panes", "-a", "-F", TmuxMapper.panesFormat]) {
            panes = TmuxMapper.parsePanes(panesOut)
        }

        // Visibility: a session whose tmux window is the active window of an
        // attached client while a terminal is frontmost is on screen. Used
        // for seen-tracking (greens) and notification silencing (reds).
        var activeWindows = Set<String>()
        if let tmuxPath,
           let clientsOut = Shell.run(tmuxPath, ["list-clients", "-F", TmuxMapper.clientsFormat]),
           let windowsOut = Shell.run(tmuxPath, ["list-windows", "-a", "-F", TmuxMapper.windowsFormat]) {
            let attached = Set(TmuxMapper.parseClients(clientsOut).map(\.sessionName))
            activeWindows = TmuxMapper.parseActiveAttachedWindows(attachedSessions: attached,
                                                                  windowsOutput: windowsOut)
        }
        // Sessions with no transcript yet (still starting, nothing said).
        var newIds = Set<String>()
        for record in records where record.kind == "interactive" {
            guard let cwd = record.cwd, let id = record.sessionId else { continue }
            let url = TranscriptReader.transcriptURL(cwd: cwd, sessionId: id)
            if !FileManager.default.fileExists(atPath: url.path) { newIds.insert(id) }
        }

        // First pass merges twin records (bg + interactive) per sessionId,
        // so visibility and seen sampling use the merged truth.
        let base = SessionBuilder.build(records: records, pidTtys: pidTtys, panes: panes,
                                        newIds: newIds)
        let all = Set(base.map(\.id))
        let greens = Set(base.filter { $0.light == .green }.map(\.id))
        var visible = Set<String>()
        if isTerminalFrontmost() {
            for session in base {
                if let tmuxSession = session.tmuxSession, let window = session.tmuxWindow,
                   activeWindows.contains(tmuxSession + ":" + window) {
                    visible.insert(session.id)
                }
            }
        }
        seen = SeenTracker.update(seen: seen, greens: greens, visible: visible, all: all)
        refreshTitles(records: records, all: all)

        let sessions = SessionBuilder.build(records: records, pidTtys: pidTtys, panes: panes,
                                            seenIds: seen, titles: titles, visibleIds: visible,
                                            newIds: newIds)
        let newlyRed = TransitionDetector.newlyRed(previous: previous, current: sessions)
        let newlyDone = TransitionDetector.newlyDone(previous: previous, current: sessions)
        previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.light) })

        DispatchQueue.main.async { [weak self] in
            self?.onSnapshot?(sessions, error)
            if !newlyRed.isEmpty { self?.onNewlyRed?(newlyRed) }
            if !newlyDone.isEmpty { self?.onNewlyDone?(newlyDone) }
        }
    }
}
