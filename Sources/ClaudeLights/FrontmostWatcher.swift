import AppKit

/// Tracks whether a known terminal app is frontmost, so the poller (on its
/// own queue) can read it without touching NSWorkspace off the main thread.
final class FrontmostWatcher {
    static let knownTerminals = ["iTerm2", "Ghostty", "WezTerm", "kitty", "Alacritty", "Terminal"]

    private let lock = NSLock()
    private var value = false

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
        return value
    }

    private func update(_ app: NSRunningApplication?) {
        let isTerminal = app?.localizedName.map { Self.knownTerminals.contains($0) } ?? false
        lock.lock(); value = isTerminal; lock.unlock()
    }
}
