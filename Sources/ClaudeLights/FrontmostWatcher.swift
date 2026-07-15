import AppKit

/// Tracks the frontmost app so the poller (on its own queue) can read it
/// without touching NSWorkspace off the main thread.
final class FrontmostWatcher {
    static let knownTerminals = ["iTerm2", "Ghostty", "WezTerm", "kitty", "Alacritty", "Terminal",
                                 "Code", "Visual Studio Code"]

    private let lock = NSLock()
    private var terminalFrontmost = false
    private var bundleID: String?

    init() {
        update(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.update(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    var isTerminalFrontmost: Bool {
        lock.lock(); defer { lock.unlock() }
        return terminalFrontmost
    }

    /// Bundle id of the frontmost app when it is a known terminal, else nil.
    var frontmostTerminalBundleID: String? {
        lock.lock(); defer { lock.unlock() }
        return terminalFrontmost ? bundleID : nil
    }

    private func update(_ app: NSRunningApplication?) {
        let isTerminal = app?.localizedName.map { Self.knownTerminals.contains($0) } ?? false
        lock.lock(); terminalFrontmost = isTerminal; bundleID = app?.bundleIdentifier; lock.unlock()
    }
}
