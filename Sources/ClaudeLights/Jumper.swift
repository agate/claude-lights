import AppKit
import ClaudeLightsCore

final class Jumper {
    private let tmuxPath = BinaryLocator.locate("tmux")

    func jump(to session: Session) {
        guard let tmuxPath,
              let tmuxSession = session.tmuxSession,
              let window = session.tmuxWindow else {
            // Not in tmux: claude runs directly in a terminal tab, so its own
            // tty is that tab's tty — focus it the same tty-matching way.
            if let tty = session.tty, focusTab(tty: tty) { return }
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
        guard !clients.isEmpty else {
            // Every terminal window is gone: offer to open one attached here.
            offerToOpenWindow(attachingTo: tmuxSession)
            return
        }
        var host: TmuxClient?
        if let attached = clients.first(where: { $0.sessionName == tmuxSession }) {
            host = attached
        } else if let any = clients.first {
            // No client shows this session: retarget one onto it.
            Shell.run(tmuxPath, ["switch-client", "-c", any.tty, "-t", "\(tmuxSession):\(window)"])
            host = any
        }

        if let host {
            // VS Code hosts all integrated terminals in one shared pty-host
            // process, so a tty can't select a window — the workspace folder
            // (the session's cwd) is the window key instead.
            if let app = guiApp(abovePid: Int32(host.pid)),
               app.bundleIdentifier == "com.microsoft.VSCode" {
                focusVSCodeWindow(cwd: session.cwd, app: app)
                return
            }
            // Focus the exact terminal window/tab hosting that client's tty.
            if focusTab(tty: host.tty) { return }
        }
        activateTerminal()
    }

    /// Focuses the terminal window/tab whose tty matches. Tries iTerm2 then
    /// Apple Terminal — each matches by tty, so only the real host says "ok".
    private func focusTab(tty: String) -> Bool {
        focusITermTab(tty: tty) || focusAppleTerminalTab(tty: tty)
    }

    /// Walks up the process ancestry until a regular GUI app is found.
    private func guiApp(abovePid start: Int32) -> NSRunningApplication? {
        var pid = start
        for _ in 0..<10 {
            if let app = NSRunningApplication(processIdentifier: pid),
               app.activationPolicy == .regular {
                return app
            }
            guard let ppidOut = Shell.run("/bin/ps", ["-o", "ppid=", "-p", String(pid)]),
                  let ppid = Int32(ppidOut.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ppid > 1 else { return nil }
            pid = ppid
        }
        return nil
    }

    /// Focuses the VS Code window whose workspace is the session's cwd; the
    /// `code` CLI reuses an existing window for a folder it already has open.
    private func focusVSCodeWindow(cwd: String, app: NSRunningApplication) {
        let bundledCLI = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        if let code = BinaryLocator.locate("code") {
            Shell.run(code, [cwd])
        } else if FileManager.default.isExecutableFile(atPath: bundledCLI) {
            Shell.run(bundledCLI, [cwd])
        } else {
            Shell.run("/usr/bin/open", ["-a", "Visual Studio Code", cwd])
        }
        app.activate(options: [.activateIgnoringOtherApps])
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

    /// No tmux client anywhere (all terminal windows closed). Ask, then open
    /// a fresh terminal window attached to the target session.
    private func offerToOpenWindow(attachingTo session: String) {
        guard let tmuxPath, let bundleId = preferredTerminalBundleId() else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "No terminal window is attached to tmux"
        alert.informativeText =
            "Open a new terminal window attached to “\(session)”?"
        alert.addButton(withTitle: "Open Window")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let attach = TmuxMapper.attachCommand(tmuxPath: tmuxPath, session: session)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        if bundleId == "com.googlecode.iterm2" {
            script = """
            tell application "iTerm2"
                activate
                create window with default profile command "\(attach)"
            end tell
            """
        } else {
            script = """
            tell application "Terminal"
                activate
                do script "\(attach)"
            end tell
            """
        }
        Shell.run("/usr/bin/osascript", ["-e", script])
    }

    /// iTerm2 or Apple Terminal — whichever is running, else installed.
    private func preferredTerminalBundleId() -> String? {
        let candidates = ["com.googlecode.iterm2", "com.apple.Terminal"]
        if let running = candidates.first(where: { id in
            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
        }) { return running }
        return candidates.first {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    /// Finds the GUI app hosting the attached tmux client by walking up its
    /// process ancestry; falls back to well-known terminal apps.
    private func activateTerminal() {
        if let tmuxPath,
           let out = Shell.run(tmuxPath, ["list-clients", "-F", "#{client_pid}"]) {
            for pidLine in out.split(separator: "\n") {
                guard let pid = Int32(pidLine.trimmingCharacters(in: .whitespaces)) else { continue }
                if let app = guiApp(abovePid: pid) {
                    app.activate(options: [.activateIgnoringOtherApps])
                    return
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
