import AppKit
import ClaudeLightsCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    let poller = Poller()
    private let jumper = Jumper()
    private let snapshotQueue = DispatchQueue(label: "ClaudeLights.snapshots")
    /// Main-thread only; recomputed off-main by refreshSnapshotEntries().
    private var cachedSnapshotEntries: [SnapshotMenuEntry] = [
        SnapshotMenuEntry(title: "Loading…", restoreName: nil, enabled: false)]
    private lazy var snapshots = SnapshotService(store: SnapshotStore(), jumper: jumper)
    private let notifier = Notifier()
    private let frontmostWatcher = FrontmostWatcher()
    private let updater: UpdaterEngine = GitHubUpdater()
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
        poller.frontmostTerminalBundleID = { [weak self] in
            self?.frontmostWatcher.frontmostTerminalBundleID
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

        updater.delegate = self
        statusController.onCheckForUpdates = { [weak self] in
            self?.updater.checkForUpdates(userInitiated: true)
        }
        statusController.onInstallUpdate = { [weak self] in
            self?.updater.installPendingUpdate()
        }
        notifier.onInstallUpdate = { [weak self] in
            self?.updater.installPendingUpdate()
        }
        updater.startPeriodicChecks()
        statusController.snapshotMenuEntries = { [weak self] in self?.cachedSnapshotEntries ?? [] }
        statusController.onMenuWillOpen = { [weak self] in self?.refreshSnapshotEntries() }
        refreshSnapshotEntries()
        statusController.onSaveSessions = { [weak self] in
            guard let self else { return }
            let sessions = self.store.sessions
            self.snapshotQueue.async {
                let body: String
                do {
                    _ = try self.snapshots.listings().get() // surfaces iCloudUnavailable
                    body = self.snapshots.saveAll(sessions: sessions)
                } catch {
                    body = error.localizedDescription
                }
                DispatchQueue.main.async {
                    self.notifier.notifyInfo(title: "Save Sessions", body: body)
                    self.refreshSnapshotEntries()
                }
            }
        }
        statusController.onRestore = { [weak self] names in
            guard let self else { return }
            self.snapshotQueue.async {
                let targets: [String]
                if let names {
                    targets = names
                } else if case .success(let listings) = self.snapshots.listings() {
                    targets = SnapshotMenu.restorableNames(listings, running: self.snapshots.runningSessionNames())
                } else {
                    targets = []
                }
                guard !targets.isEmpty else { return }
                let body = self.snapshots.restore(names: targets)
                DispatchQueue.main.async {
                    self.notifier.notifyInfo(title: "Restore", body: body)
                    self.refreshSnapshotEntries()
                }
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

extension AppDelegate: UpdaterEngineDelegate {
    private static let lastNotifiedKey = "lastNotifiedUpdateVersion"

    func updaterFoundUpdate(version: String) {
        statusController.pendingUpdateVersion = version
        let last = UserDefaults.standard.string(forKey: Self.lastNotifiedKey)
        if UpdatePolicy.shouldNotify(version: version, lastNotified: last) {
            UserDefaults.standard.set(version, forKey: Self.lastNotifiedKey)
            notifier.notifyUpdate(version: version)
        }
        // Demo hook: install a found update immediately, without a click —
        // lets the full download→swap→relaunch path run unattended.
        if ProcessInfo.processInfo.environment["CLAUDE_LIGHTS_DEMO_AUTOINSTALL"] != nil {
            updater.installPendingUpdate()
        }
    }

    func updaterIsUpToDate(userInitiated: Bool) {
        guard userInitiated else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        updateAlert(title: "You're up to date",
                    text: "Claude Lights \(version.map { "v\($0)" } ?? "") is the latest version.")
    }

    func updaterFailed(error: String, userInitiated: Bool) {
        guard userInitiated else { return } // background checks fail silently
        updateAlert(title: "Update check failed", text: error)
    }

    func updaterWillInstall() {}

    private func updateAlert(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    private func refreshSnapshotEntries() {
        snapshotQueue.async { [weak self] in
            guard let self else { return }
            let entries: [SnapshotMenuEntry]
            switch self.snapshots.listings() {
            case .success(let listings):
                entries = SnapshotMenu.entries(listings, running: self.snapshots.runningSessionNames())
            case .failure(let error):
                entries = [SnapshotMenuEntry(title: error.localizedDescription, restoreName: nil,
                                             enabled: false)]
            }
            DispatchQueue.main.async { self.cachedSnapshotEntries = entries }
        }
    }
}
