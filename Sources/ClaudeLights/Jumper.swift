import AppKit
import ClaudeLightsCore

final class Jumper {
    private let tmuxPath = BinaryLocator.locate("tmux")

    func jump(to session: Session) {
        guard let tmuxPath,
              let tmuxSession = session.tmuxSession,
              let window = session.tmuxWindow else {
            activateTerminal()
            return
        }
        // Make the claude window/pane current inside its tmux session.
        Shell.run(tmuxPath, ["select-window", "-t", "\(tmuxSession):\(window)"])
        if let paneId = session.tmuxPane {
            Shell.run(tmuxPath, ["select-pane", "-t", paneId])
        }

        // Find (or retarget) the client that shows this tmux session.
        let clients = TmuxMapper.parseClients(
            Shell.run(tmuxPath, ["list-clients", "-F", TmuxMapper.clientsFormat]) ?? "")
        var hostTty: String?
        if let attached = clients.first(where: { $0.sessionName == tmuxSession }) {
            hostTty = attached.tty
        } else if let any = clients.first {
            // No client shows this session: retarget one onto it.
            Shell.run(tmuxPath, ["switch-client", "-c", any.tty, "-t", "\(tmuxSession):\(window)"])
            hostTty = any.tty
        }

        // Focus the exact terminal window/tab hosting that client's tty.
        // Each focuser matches by tty, so trying both is safe — only the app
        // actually hosting the tty reports "ok".
        if let hostTty {
            if focusITermTab(tty: hostTty) { return }
            if focusAppleTerminalTab(tty: hostTty) { return }
        }
        activateTerminal()
    }

    /// Selects the iTerm2 window + tab + split whose tty hosts the tmux
    /// client, via iTerm2's AppleScript interface. Returns false when iTerm2
    /// is not running, the tty is not found, or automation is not permitted.
    private func focusITermTab(tty: String) -> Bool {
        runFocusScript(bundleId: "com.googlecode.iterm2", script: """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "not found"
        """)
    }

    /// Same for Apple Terminal, whose tabs expose a tty property directly.
    private func focusAppleTerminalTab(tty: String) -> Bool {
        runFocusScript(bundleId: "com.apple.Terminal", script: """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "not found"
        """)
    }

    /// Runs an AppleScript focuser if its app is running; true only when the
    /// script found and focused the tty's tab.
    private func runFocusScript(bundleId: String, script: String) -> Bool {
        guard NSWorkspace.shared.runningApplications
            .contains(where: { $0.bundleIdentifier == bundleId }) else { return false }
        let out = Shell.run("/usr/bin/osascript", ["-e", script])
        return out?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    /// Finds the GUI app hosting the attached tmux client by walking up its
    /// process ancestry; falls back to well-known terminal apps.
    private func activateTerminal() {
        if let tmuxPath,
           let out = Shell.run(tmuxPath, ["list-clients", "-F", "#{client_pid}"]) {
            for pidLine in out.split(separator: "\n") {
                guard var pid = Int32(pidLine.trimmingCharacters(in: .whitespaces)) else { continue }
                for _ in 0..<10 {
                    if let app = NSRunningApplication(processIdentifier: pid),
                       app.activationPolicy == .regular {
                        app.activate(options: [.activateIgnoringOtherApps])
                        return
                    }
                    guard let ppidOut = Shell.run("/bin/ps", ["-o", "ppid=", "-p", String(pid)]),
                          let ppid = Int32(ppidOut.trimmingCharacters(in: .whitespacesAndNewlines)),
                          ppid > 1 else { break }
                    pid = ppid
                }
            }
        }
        fallbackActivate()
    }

    private func fallbackActivate() {
        for name in FrontmostWatcher.knownTerminals {
            if let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.localizedName == name }) {
                app.activate(options: [.activateIgnoringOtherApps])
                return
            }
        }
    }
}
