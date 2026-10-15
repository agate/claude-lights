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

    private func baseIndex() -> Int? {
        Int(Tmux.run(["show-options", "-gv", "base-index"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// Snapshots of every running tmux session plus the loose one. When tmux
    /// is not running, only the loose snapshot (if any) is returned.
    func build(sessions: [Session]) -> (snaps: [Snapshot], tmuxRunning: Bool) {
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
            baseIndex: tmuxRunning ? (baseIndex() ?? 0) : 0)
        return (snaps, tmuxRunning)
    }

    func write(_ snap: Snapshot, savedAt: String) throws {
        try store.write(SnapshotFile(savedAt: savedAt, session: snap))
    }

    /// Writes one file per running tmux session plus the loose snapshot.
    /// Files of sessions not running now are left untouched.
    func saveAll(sessions: [Session]) -> String {
        let (snaps, tmuxRunning) = build(sessions: sessions)
        let savedAt = SnapshotCodec.timestamp(Date())
        var tmuxCount = 0, looseCount = 0
        var failures: [String] = []
        for snap in snaps {
            do {
                try write(snap, savedAt: savedAt)
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
                var snap = try store.read(name: name).session
                guard !snap.windows.isEmpty else {
                    problems.append("\(name): snapshot has no windows")
                    continue
                }
                var failure = run(RestorePlan.newSession(snap), environment: Tmux.serverEnvironment)
                let created = failure == nil
                if created {
                    if let base = baseIndex() {
                        snap = RestorePlan.rebasedLoose(snap, baseIndex: base)
                        let cmds = RestorePlan.commands(snap, baseIndex: base)
                        failure = cmds.lazy.compactMap({ self.run($0) }).first
                    } else {
                        failure = "could not read tmux base-index"
                    }
                }
                if let error = failure {
                    if created {
                        // Remove the half-built session so a later Restore is not blocked.
                        _ = Tmux.run(["kill-session", "-t", "=" + name])
                        problems.append("\(name): \(error) (rolled back)")
                    } else {
                        problems.append("\(name): \(error)")
                    }
                    continue
                }
                restored.append(name)
                if !jumper.openTerminalWindow(attachingTo: name) {
                    problems.append("\(name): restored, but could not open a terminal window — run: tmux attach -t \(name)")
                }
            } catch {
                problems.append("\(name): \(error.localizedDescription)")
            }
        }
        var body = restored.isEmpty ? "Nothing restored" : "Restored " + restored.joined(separator: ", ")
        if !problems.isEmpty { body += "\n" + problems.joined(separator: "\n") }
        return body
    }

    /// Deletes one saved snapshot file; a running tmux session is not touched.
    func delete(name: String) -> String {
        do {
            try store.delete(name: name)
            return "Deleted \(name)"
        } catch {
            return "Could not delete \(name): \(error.localizedDescription)"
        }
    }

    /// nil on success, else tmux's error text.
    private func run(_ args: [String], environment: [String: String]? = nil) -> String? {
        guard let r = Tmux.runResult(args, environment: environment) else { return "could not launch tmux" }
        guard r.status != 0 else { return nil }
        let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "tmux \(args.first ?? ""): \(msg.isEmpty ? "exit \(r.status)" : msg)"
    }
}
