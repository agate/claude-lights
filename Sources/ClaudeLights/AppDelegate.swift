import AppKit
import ClaudeLightsCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    let poller = Poller()
    private let jumper = Jumper()
    private let closer = SessionCloser()
    private let snapshotQueue = DispatchQueue(label: "ClaudeLights.snapshots")
    /// Main-thread only; recomputed off-main by refreshSnapshotEntries().
    private var cachedSnapshotEntries: [SnapshotMenuEntry] = [
        SnapshotMenuEntry(title: "Loading…", restoreName: nil, enabled: false)]
    private var cachedAutoSnapshotEntries: [SnapshotMenuEntry] = [
        SnapshotMenuEntry(title: "Loading…", restoreName: nil, enabled: false)]
    private lazy var snapshots = SnapshotService(store: SnapshotStore(), jumper: jumper)
    /// Written by the auto-save timer; kept apart so it never overwrites a manual save.
    private lazy var autoSnapshots = SnapshotService(
        store: SnapshotStore(subfolder: "auto-saved"), jumper: jumper)
    private static let autoSaveKey = "autoSaveSessions"
    private static let autoSaveInterval: TimeInterval = 15
    /// snapshotQueue only.
    private var autoSaveTracker = AutoSaveTracker()
    /// snapshotQueue only; last error logged per snapshot name, so a lasting
    /// failure is logged once, not every tick.
    private var autoSaveLastErrors: [String: String] = [:]
    private let autoSaveLog = ErrorLog(fileName: "autosave.log")
    private var autoSaveTimer: DispatchSourceTimer?
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
        statusController.onCloseSession = { [weak self] session in
            self?.confirmClose(session)
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
        statusController.onDeleteSnapshot = { [weak self] name in
            guard let self else { return }
            self.confirmDelete(name: name, from: self.snapshots)
        }
        statusController.onRestore = { [weak self] names in
            guard let self else { return }
            self.restore(names: names, from: self.snapshots)
        }
        statusController.autoSnapshotMenuEntries = { [weak self] in
            self?.cachedAutoSnapshotEntries ?? []
        }
        statusController.onDeleteAutoSnapshot = { [weak self] name in
            guard let self else { return }
            self.confirmDelete(name: name, from: self.autoSnapshots)
        }
        statusController.onRestoreAuto = { [weak self] names in
            guard let self else { return }
            self.restore(names: names, from: self.autoSnapshots)
        }
        UserDefaults.standard.register(defaults: [Self.autoSaveKey: true])
        statusController.isAutoSaveOn = { UserDefaults.standard.bool(forKey: Self.autoSaveKey) }
        statusController.onToggleAutoSave = { [weak self] in
            let on = !UserDefaults.standard.bool(forKey: Self.autoSaveKey)
            UserDefaults.standard.set(on, forKey: Self.autoSaveKey)
            if on { self?.autoSaveTick() }
        }
        // Dispatch timer, like the Poller's: a main-run-loop Timer gets
        // stretched by App Nap while the app sits in the background.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.autoSaveInterval, repeating: Self.autoSaveInterval)
        timer.setEventHandler { [weak self] in self?.autoSaveTick() }
        timer.resume()
        autoSaveTimer = timer
    }

    private func confirmDelete(name: String, from service: SnapshotService) {
        // LSUIElement app: activate or the alert opens behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Delete saved session “\(name)”?"
        alert.informativeText = "Only the saved snapshot is removed. A running tmux session is not affected."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        snapshotQueue.async {
            let body = service.delete(name: name)
            if service === self.autoSnapshots { self.autoSaveTracker.forget(name) }
            DispatchQueue.main.async {
                self.notifier.notifyInfo(title: "Delete Saved Session", body: body)
                self.refreshSnapshotEntries()
            }
        }
    }

    /// Both entry points (tray ⌥ row, bar right-click) land here.
    private func confirmClose(_ session: Session) {
        // LSUIElement app: activate or the alert opens behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Close “\(session.displayName)”?"
        var body = [CloseTarget.for(session).description(for: session)]
        if session.light == .yellow { body.append("It is working right now.") }
        if session.backgroundTasks > 0 {
            let n = session.backgroundTasks
            body.append("The \(n) command\(n == 1 ? "" : "s") it started will be stopped too.")
        }
        alert.informativeText = body.joined(separator: "\n\n")
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let error = self.closer.close(session) else { return }
            DispatchQueue.main.async {
                self.notifier.notifyInfo(title: "Close Session", body: error)
            }
        }
    }

    /// nil names means "Restore All" of that store.
    private func restore(names: [String]?, from service: SnapshotService) {
        snapshotQueue.async {
            let targets: [String]
            if let names {
                targets = names
            } else if case .success(let listings) = service.listings() {
                targets = SnapshotMenu.restorableNames(listings, running: service.runningSessionNames())
            } else {
                targets = []
            }
            guard !targets.isEmpty else { return }
            let body = service.restore(names: targets)
            DispatchQueue.main.async {
                self.notifier.notifyInfo(title: "Restore", body: body)
                self.refreshSnapshotEntries()
            }
        }
    }

    /// Writes changed, settled snapshots to the auto-saved store. Silent:
    /// failures go to ~/Library/Logs/ClaudeLights/autosave.log only.
    private func autoSaveTick() {
        guard UserDefaults.standard.bool(forKey: Self.autoSaveKey) else { return }
        let sessions = store.sessions
        snapshotQueue.async { [weak self] in
            guard let self else { return }
            let due = self.autoSaveTracker.due(self.autoSnapshots.build(sessions: sessions).snaps)
            guard !due.isEmpty else { return }
            let savedAt = SnapshotCodec.timestamp(Date())
            for snap in due {
                do {
                    try self.autoSnapshots.write(snap, savedAt: savedAt)
                    self.autoSaveTracker.markWritten(snap)
                    self.autoSaveLastErrors[snap.name] = nil
                } catch {
                    let message = error.localizedDescription
                    if self.autoSaveLastErrors[snap.name] != message {
                        self.autoSaveLastErrors[snap.name] = message
                        self.autoSaveLog.log("\(snap.name): \(message)")
                    }
                }
            }
            DispatchQueue.main.async { self.refreshSnapshotEntries() }
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
            let running = self.snapshots.runningSessionNames()
            let entries = Self.menuEntries(self.snapshots, running: running)
            let autoEntries = Self.menuEntries(self.autoSnapshots, running: running)
            DispatchQueue.main.async {
                self.cachedSnapshotEntries = entries
                self.cachedAutoSnapshotEntries = autoEntries
            }
        }
    }

    private static func menuEntries(_ service: SnapshotService,
                                    running: Set<String>) -> [SnapshotMenuEntry] {
        switch service.listings() {
        case .success(let listings):
            return SnapshotMenu.entries(listings, running: running)
        case .failure(let error):
            return [SnapshotMenuEntry(title: error.localizedDescription, restoreName: nil,
                                      enabled: false)]
        }
    }
}
