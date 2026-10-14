import Foundation

/// Runs tmux commands, locating the server socket explicitly.
///
/// Without `-S`, tmux looks in `$TMUX_TMPDIR`, else `/tmp` (never `$TMPDIR`).
/// A user's shell may set a custom `TMUX_TMPDIR` that a Finder-launched app
/// does not inherit, so the server would not be found and every command came
/// back empty — which broke jumping to tmux sessions. Hence the explicit
/// `-S` scan below.
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

    /// Environment for a tmux server this app starts (Restore after a reboot).
    /// A Finder-launched app has no `LANG` and a bare `PATH`, which the server
    /// would pass on to every shell: broken UTF-8 and missing tools.
    static let serverEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        if let p = Shell.run("/bin/zsh", ["-lc", "printf %s \"$PATH\""])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            env["PATH"] = p
        }
        if (env["LANG"] ?? "").isEmpty {
            var locale = Shell.run("/usr/bin/defaults", ["read", "-g", "AppleLocale"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let at = locale.firstIndex(of: "@") { locale = String(locale[..<at]) }
            env["LANG"] = locale.isEmpty ? "en_US.UTF-8" : locale + ".UTF-8"
        }
        return env
    }()

    @discardableResult
    static func run(_ args: [String]) -> String? {
        guard let path else { return nil }
        return Shell.run(path, socketArgs() + args)
    }

    /// Like `run`, but keeps the exit status and stderr for error reporting.
    static func runResult(_ args: [String],
                          environment: [String: String]? = nil) -> ShellResult? {
        guard let path else { return nil }
        return Shell.runResult(path, socketArgs() + args, environment: environment)
    }
}
