import Foundation

/// Snapshot of `ps -ax -o pid=,ppid=,pgid=,tpgid=,args=`.
public struct ProcessTable: Sendable {
    public static let psArguments = ["-ax", "-o", "pid=,ppid=,pgid=,tpgid=,args="]

    struct Proc: Sendable { let pgid: Int; let tpgid: Int; let args: String; var children: [Int] }
    private(set) var procs: [Int: Proc] = [:]

    public static func parse(_ output: String) -> ProcessTable {
        var table = ProcessTable()
        var parents: [Int: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int(parts[0]), let ppid = Int(parts[1]),
                  let pgid = Int(parts[2]), let tpgid = Int(parts[3]) else { continue }
            let args = parts.count > 4 ? String(parts[4]) : ""
            table.procs[pid] = Proc(pgid: pgid, tpgid: tpgid, args: args, children: [])
            parents[pid] = ppid
        }
        for (pid, ppid) in parents where table.procs[ppid] != nil {
            table.procs[ppid]?.children.append(pid)
        }
        return table
    }

    /// Command line in the foreground of a pane's shell, or nil when the
    /// shell is idle. The shell's direct children in the terminal's
    /// foreground process group are joined with " | ", so a pipeline comes
    /// back whole. `ps` does not keep the original quoting.
    public func foregroundCommand(shellPid: Int) -> String? {
        guard let shell = procs[shellPid],
              shell.tpgid > 0, shell.tpgid != shell.pgid else { return nil }
        let fg = shell.tpgid
        var members = shell.children.filter { procs[$0]?.pgid == fg }.sorted()
        if members.isEmpty, procs[fg] != nil { members = [fg] }
        let line = members.compactMap { procs[$0]?.args }.joined(separator: " | ")
        return line.isEmpty ? nil : line
    }
}
