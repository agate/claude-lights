import Foundation

/// Tracks which idle (green) sessions the user has already looked at.
/// A session counts as seen when the user jumped to it from the app, or when
/// it was the focused pane of the focused tmux window while the terminal app
/// was frontmost. Leaving green (busy/waiting again) resets it.
public enum SeenTracker {
    /// - Parameters:
    ///   - seen: previously seen session ids
    ///   - greens: ids currently in the green family
    ///   - visible: ids currently on screen in front of the user
    ///   - all: all current session ids (for pruning gone sessions)
    public static func update(seen: Set<String>,
                              greens: Set<String>,
                              visible: Set<String>,
                              all: Set<String>) -> Set<String> {
        var next = seen.intersection(all)
        next.subtract(all.subtracting(greens))
        next.formUnion(visible.intersection(greens))
        return next
    }

    /// Ids of the sessions the user is actually looking at.
    ///
    /// Window granularity is not enough: a split window shows several panes
    /// at once, so every session in it would be marked read together even
    /// though only one was focused. Require the session's own pane to be its
    /// window's active pane. A session with no pane id is never focused —
    /// the conservative choice, matching the frontmost-tty check.
    public static func focusedIds(sessions: [Session],
                                  focusedSessionName: String?,
                                  activeWindows: Set<String>,
                                  activePaneIds: Set<String>) -> Set<String> {
        guard let focusedSessionName else { return [] }
        var result = Set<String>()
        for session in sessions {
            guard session.tmuxSession == focusedSessionName,
                  let window = session.tmuxWindow,
                  activeWindows.contains(focusedSessionName + ":" + window),
                  let pane = session.tmuxPane,
                  activePaneIds.contains(pane) else { continue }
            result.insert(session.id)
        }
        return result
    }
}
