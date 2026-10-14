import Foundation

/// Turns a snapshot into the ordered tmux commands that rebuild it.
public enum RestorePlan {
    /// Creates the session (and the tmux server, if none runs). Run first.
    public static func newSession(_ s: Snapshot) -> [String] {
        let first = s.windows.first
        return ["new-session", "-d", "-s", s.name, "-c", s.path,
                "-x", String(first?.width ?? 200), "-y", String(first?.height ?? 50)]
    }

    /// Everything after `newSession`. `baseIndex` is the server's
    /// `base-index`, i.e. the index new-session gave the first window.
    public static func commands(_ s: Snapshot, baseIndex: Int) -> [[String]] {
        var out: [[String]] = []
        for (i, w) in s.windows.enumerated() {
            let target = "\(s.name):\(w.index)"
            let startCwd = w.panes.first?.cwd ?? s.path
            if i == 0 {
                if w.index != baseIndex {
                    out.append(["move-window", "-s", "\(s.name):\(baseIndex)", "-t", target])
                }
                if startCwd != s.path {
                    out.append(["send-keys", "-t", target, "cd \(shellQuote(startCwd)) && clear", "Enter"])
                }
            } else {
                out.append(["new-window", "-d", "-t", target, "-c", startCwd])
            }
            for p in w.panes.dropFirst() {
                out.append(["split-window", "-d", "-t", target, "-c", p.cwd])
            }
            let multi = w.panes.count > 1
            if multi { out.append(["select-layout", "-t", target, w.layout]) }
            out.append(["rename-window", "-t", target, w.name])
            out.append(["set-option", "-w", "-t", target, "automatic-rename",
                        w.automaticRename ? "on" : "off"])
            for p in w.panes {
                // A lone pane is addressed by its window, so pane-base-index never matters.
                let pane = multi ? "\(target).\(p.index)" : target
                if let line = resumeLine(p) {
                    out.append(["send-keys", "-t", pane, line, "Enter"])
                } else if let cmd = p.command {
                    // Typed but not run: the user reviews it and presses Enter.
                    out.append(["send-keys", "-t", pane, "-l", cmd])
                }
            }
            if multi, let active = w.panes.first(where: \.active) {
                out.append(["select-pane", "-t", "\(target).\(active.index)"])
            }
            if w.zoomed { out.append(["resize-pane", "-Z", "-t", target]) }
        }
        if let active = s.windows.first(where: \.active) {
            out.append(["select-window", "-t", "\(s.name):\(active.index)"])
        }
        return out
    }

    public static func resumeLine(_ pane: SnapshotPane) -> String? {
        guard let c = pane.claude else { return nil }
        let cwd = c.cwd ?? pane.cwd
        return "cd \(shellQuote(cwd)) && claude --resume \(shellQuote(c.sessionId))"
    }

    /// POSIX shell quoting, same rules as Python's shlex.quote.
    public static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
