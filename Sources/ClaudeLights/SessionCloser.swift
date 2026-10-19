import AppKit
import ClaudeLightsCore

/// Closes a session: stops its Claude process(es) and the commands they
/// started, then removes Claude's own tmux/herdr pane or terminal tab.
/// Blocking (waits up to `grace` for exits) — call off the main thread.
final class SessionCloser {
    private let grace: TimeInterval = 3

    /// Returns an error sentence, or nil when the session was closed.
    func close(_ session: Session) -> String? {
        // A pid counts only while its registry record still names this
        // session: the process may have exited and the pid been reused.
        let pids = session.pids.filter { isRegistered(pid: $0, sessionId: session.id) }

        // Collect command groups before signalling Claude: once it exits its
        // children are re-parented to launchd and no longer findable by parent.
        var groups: [Int32] = []
        if !pids.isEmpty, let psOut = Shell.run("/bin/ps", ProcessTable.psArguments) {
            let procs = ProcessTable.parse(psOut)
            groups = pids.flatMap { procs.claudeCommandGroups(claudePid: $0) }.map(Int32.init)
        }

        var error: String?
        for pgid in groups { kill(-pgid, SIGTERM) }
        for pid in pids where kill(Int32(pid), SIGTERM) != 0 && errno == EPERM {
            error = "Not allowed to stop Claude (pid \(pid))."
        }
        if error != nil { return error }

        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, (pids.contains(where: alive) || groups.contains(where: groupAlive)) {
            usleep(100_000)
        }
        // ESRCH (already gone) is the expected outcome here and ignored.
        for pgid in groups where groupAlive(pgid) { kill(-pgid, SIGKILL) }
        for pid in pids where alive(pid) && isRegistered(pid: pid, sessionId: session.id) {
            kill(Int32(pid), SIGKILL)
        }

        removeContainer(CloseTarget.for(session))
        return nil
    }

    private func alive(_ pid: Int) -> Bool { kill(Int32(pid), 0) == 0 || errno == EPERM }

    private func groupAlive(_ pgid: Int32) -> Bool { kill(-pgid, 0) == 0 || errno == EPERM }

    private func isRegistered(pid: Int, sessionId: String) -> Bool {
        let url = SessionRegistry.defaultDir.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(AgentRecord.self, from: data) else { return false }
        return (record.sessionId ?? String(pid)) == sessionId
    }

    private func removeContainer(_ target: CloseTarget) {
        switch target {
        case .tmuxPane(let id):
            // Fails harmlessly when the pane already died with Claude.
            Tmux.run(["kill-pane", "-t", id])
        case .herdrPane(let id):
            Herdr.run(["pane", "close", id])
        case .terminalTab(let tty):
            // Only the tab whose tty matched — never a fallback tab.
            _ = closeITermSession(tty: tty) || closeAppleTerminalTab(tty: tty)
        case .processOnly:
            break
        }
    }

    private func closeITermSession(tty: String) -> Bool {
        runScript(bundleId: "com.googlecode.iterm2", script: """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            close s
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "not found"
        """)
    }

    /// Terminal's AppleScript cannot close a single tab, only a window: close
    /// the window when the tab is its only one, else leave the tab open.
    private func closeAppleTerminalTab(tty: String) -> Bool {
        runScript(bundleId: "com.apple.Terminal", script: """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        if (count of tabs of w) is 1 then close w
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "not found"
        """)
    }

    /// Same contract as Jumper's focus scripts: runs only if the app is up,
    /// true only when the script found the tty.
    private func runScript(bundleId: String, script: String) -> Bool {
        guard NSWorkspace.shared.runningApplications
            .contains(where: { $0.bundleIdentifier == bundleId }) else { return false }
        let out = Shell.run("/usr/bin/osascript", ["-e", script])
        return out?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }
}
