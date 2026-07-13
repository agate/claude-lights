import Foundation

/// Tracks which idle (green) sessions the user has already looked at.
/// A session counts as seen when the user jumped to it from the app, or when
/// its tmux window was the active window of an attached client while the
/// terminal app was frontmost. Leaving green (busy/waiting again) resets it.
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
}
