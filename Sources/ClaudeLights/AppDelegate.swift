import AppKit
import ClaudeLightsCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    let poller = Poller()
    private let jumper = Jumper()
    private let notifier = Notifier()
    private let frontmostWatcher = FrontmostWatcher()
    private var statusController: StatusItemController!
    private var bar: FloatingBar!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController()
        bar = FloatingBar(store: store) { [weak self] session in
            self?.jump(to: session)
        }
        statusController.onJump = { [weak self] session in
            self?.jump(to: session)
        }
        statusController.onToggleBar = { [weak self] in
            guard let self else { return }
            self.bar.toggle()
            // Rebuild the menu so the checkmark reflects the new state at once.
            self.statusController.update(sessions: self.store.sessions, error: self.store.errorText)
        }
        statusController.isBarShown = { [weak self] in self?.bar.isShown ?? true }

        notifier.setup()
        notifier.onJump = { [weak self] sessionId in
            guard let session = self?.store.sessions.first(where: { $0.id == sessionId }) else { return }
            self?.jump(to: session)
        }
        poller.isTerminalFrontmost = { [weak self] in
            self?.frontmostWatcher.isTerminalFrontmost ?? false
        }

        let snapshotDir = ProcessInfo.processInfo.environment["CLAUDE_LIGHTS_DEMO_SNAPSHOT_DIR"]
        var snapshotCounter = 0
        poller.onSnapshot = { [weak self] sessions, error in
            guard let self else { return }
            self.store.sessions = sessions
            self.store.errorText = error
            self.statusController.update(sessions: sessions, error: error)
            self.bar.refresh()
            if let snapshotDir {
                snapshotCounter += 1
                self.bar.snapshot(to: URL(fileURLWithPath: snapshotDir)
                    .appendingPathComponent(String(format: "bar-%04d.png", snapshotCounter)))
            }
        }
        poller.onNewlyRed = { [weak self] sessions in
            for session in sessions {
                // Prefer the registry's own wait reason; enrich with transcript context.
                let lines = TranscriptReader.tailLines(
                    of: TranscriptReader.transcriptURL(cwd: session.cwd, sessionId: session.id))
                let transcript = TranscriptReader.waitingDescription(fromJSONLines: lines)
                let description: String?
                switch (session.waitingFor, transcript) {
                case let (reason?, detail?): description = "\(reason) — \(detail)"
                case let (reason?, nil): description = reason
                case let (nil, detail): description = detail
                }
                self?.notifier.notify(session, description: description)
            }
        }
        poller.onNewlyDone = { [weak self] sessions in
            for session in sessions {
                // The last assistant message is the natural completion summary.
                let lines = TranscriptReader.tailLines(
                    of: TranscriptReader.transcriptURL(cwd: session.cwd, sessionId: session.id))
                let description = TranscriptReader.waitingDescription(fromJSONLines: lines)
                self?.notifier.notifyDone(session, description: description)
            }
        }
        poller.start()

        if ProcessInfo.processInfo.environment["CLAUDE_LIGHTS_DEBUG_CLICK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.bar.debugLogHitTest()
                self?.bar.debugSyntheticClick()
            }
        }

        // Demo hook: CLAUDE_LIGHTS_DEMO_OPEN_MENU=<seconds> pops the tray
        // menu after a delay so screenshots can be taken unattended.
        if let raw = ProcessInfo.processInfo.environment["CLAUDE_LIGHTS_DEMO_OPEN_MENU"],
           let delay = TimeInterval(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.statusController.openMenu()
            }
        }
    }

    /// Jumping to a session counts as looking at it.
    private func jump(to session: Session) {
        if let logPath = ProcessInfo.processInfo.environment["CLAUDE_LIGHTS_DEBUG_LOG"],
           let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile()
            h.write("jump invoked for \(session.id)\n".data(using: .utf8)!)
            try? h.close()
        }
        poller.markSeen(session.id)
        jumper.jump(to: session)
    }
}
