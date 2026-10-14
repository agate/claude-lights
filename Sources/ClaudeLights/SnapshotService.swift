import Foundation
import ClaudeLightsCore

/// Captures and rebuilds sessions. Blocking (runs tmux/ps): call off the main thread.
final class SnapshotService {
    private let store: SnapshotStore
    private let jumper: Jumper

    init(store: SnapshotStore, jumper: Jumper) {
        self.store = store
        self.jumper = jumper
    }

    func runningSessionNames() -> Set<String> {
        let out = Tmux.run(["list-sessions", "-F", "#{session_name}"]) ?? ""
        return Set(out.split(separator: "\n").map(String.init))
    }

    func listings() -> Result<[SnapshotListing], Error> {
        Result { try store.list() }
    }

    private func baseIndex() -> Int {
        Int(Tmux.run(["show-options", "-gv", "base-index"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    /// Writes one file per running tmux session plus the loose snapshot.
    /// Files of sessions not running now are left untouched.
    func saveAll(sessions: [Session]) -> String {
        let tmuxOut = Tmux.run(["list-sessions", "-F", SnapshotTmux.sessionsFormat])
        let tmuxRunning = tmuxOut != nil
        let snaps = SnapshotBuilder.all(
            tmuxSessions: SnapshotTmux.parseSessions(tmuxOut ?? ""),
            windows: SnapshotTmux.parseWindows(
                Tmux.run(["list-windows", "-a", "-F", SnapshotTmux.windowsFormat]) ?? ""),
            panes: SnapshotTmux.parsePanes(
                Tmux.run(["list-panes", "-a", "-F", SnapshotTmux.panesFormat]) ?? ""),
            sessions: sessions,
            procs: ProcessTable.parse(Shell.run("/bin/ps", ProcessTable.psArguments) ?? ""),
            home: NSHomeDirectory(),
            baseIndex: tmuxRunning ? baseIndex() : 0)
        let savedAt = SnapshotCodec.timestamp(Date())
        var tmuxCount = 0, looseCount = 0
        var failures: [String] = []
        for snap in snaps {
            do {
                try store.write(SnapshotFile(savedAt: savedAt, session: snap))
                if snap.name == SnapshotCodec.looseName {
                    looseCount = snap.windows.count
                } else {
                    tmuxCount += 1
                }
            } catch {
                failures.append("\(snap.name): \(error.localizedDescription)")
            }
        }
        var body = "Saved \(tmuxCount) tmux session\(tmuxCount == 1 ? "" : "s")"
            + " + \(looseCount) loose session\(looseCount == 1 ? "" : "s")"
        if !tmuxRunning { body += " (tmux not running, skipped)" }
        if !failures.isEmpty { body += "\nFailed: " + failures.joined(separator: "; ") }
        return body
    }

    /// Rebuilds each named snapshot that is not already running, opening one
    /// terminal window per restored session.
    func restore(names: [String]) -> String {
        guard Tmux.available else { return "tmux is not installed" }
        var restored: [String] = []
        var problems: [String] = []
        for name in names {
            if runningSessionNames().contains(name) {
                problems.append("\(name): already running")
                continue
            }
            do {
                let snap = try store.read(name: name).session
                guard !snap.windows.isEmpty else {
                    problems.append("\(name): snapshot has no windows")
                    continue
                }
                if let error = run(RestorePlan.newSession(snap)) {
                    problems.append("\(name): \(error)")
                    continue
                }
                let cmds = RestorePlan.commands(snap, baseIndex: baseIndex())
                if let error = cmds.lazy.compactMap({ self.run($0) }).first {
                    problems.append("\(name): \(error)")
                }
                // Open the window even after a partial failure, so the user sees what was built.
                jumper.openTerminalWindow(attachingTo: name)
                restored.append(name)
            } catch {
                problems.append("\(name): \(error.localizedDescription)")
            }
        }
        var body = restored.isEmpty ? "Nothing restored" : "Restored " + restored.joined(separator: ", ")
        if !problems.isEmpty { body += "\n" + problems.joined(separator: "\n") }
        return body
    }

    /// nil on success, else tmux's error text.
    private func run(_ args: [String]) -> String? {
        guard let r = Tmux.runResult(args) else { return "could not launch tmux" }
        guard r.status != 0 else { return nil }
        let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "tmux \(args.first ?? ""): \(msg.isEmpty ? "exit \(r.status)" : msg)"
    }
}
