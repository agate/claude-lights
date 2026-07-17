import Foundation

/// Runs tmux commands, locating the server socket explicitly.
///
/// A GUI app launched from Finder gets launchd's `$TMPDIR`
/// (`/var/folders/.../T`), but a tmux server started from a terminal often
/// lives under `/tmp` (or a custom `$TMUX_TMPDIR`). Without `-S`, tmux looks
/// in the app's `$TMPDIR`, fails to find the running server, and every
/// command comes back empty — which broke jumping to tmux sessions.
enum Tmux {
    static let path = BinaryLocator.locate("tmux")

    static var available: Bool { path != nil }

    /// `-S <socket>` for the running default server, or [] if the default
    /// location already works. Recomputed each call so a server that starts
    /// after launch is picked up.
    private static func socketArgs() -> [String] {
        let uid = getuid()
        var dirs: [String] = []
        let env = ProcessInfo.processInfo.environment
        if let t = env["TMUX_TMPDIR"], !t.isEmpty { dirs.append(t) }
        if let t = env["TMPDIR"], !t.isEmpty { dirs.append(t) }
        dirs.append("/tmp")
        for dir in dirs {
            let socket = (dir as NSString).appendingPathComponent("tmux-\(uid)/default")
            if FileManager.default.fileExists(atPath: socket) { return ["-S", socket] }
        }
        return []
    }

    @discardableResult
    static func run(_ args: [String]) -> String? {
        guard let path else { return nil }
        return Shell.run(path, socketArgs() + args)
    }
}
