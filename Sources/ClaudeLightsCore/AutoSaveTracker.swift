import Foundation

/// Decides which snapshots auto-save should write. A snapshot is due when it
/// differs from what was last written and was seen unchanged on two ticks in
/// a row, so a shutdown tearing panes down tick by tick never overwrites a
/// good file. Claude's live status is ignored: it changes constantly and
/// restore does not use it.
public struct AutoSaveTracker: Sendable {
    private var written: [String: Snapshot] = [:]
    private var pending: [String: Snapshot] = [:]

    public init() {}

    /// Snapshots to write this tick; call `markWritten` for each one that succeeds.
    public mutating func due(_ snaps: [Snapshot]) -> [Snapshot] {
        var nextPending: [String: Snapshot] = [:]
        var out: [Snapshot] = []
        for snap in snaps {
            let key = Self.normalized(snap)
            if written[snap.name] == key { continue }
            if pending[snap.name] == key { out.append(snap) }
            nextPending[snap.name] = key
        }
        pending = nextPending
        return out
    }

    public mutating func markWritten(_ snap: Snapshot) {
        written[snap.name] = Self.normalized(snap)
    }

    /// Call after the snapshot's file is deleted, so a still-running session is saved again.
    public mutating func forget(_ name: String) {
        written[name] = nil
        pending[name] = nil
    }

    static func normalized(_ snap: Snapshot) -> Snapshot {
        var s = snap
        for w in s.windows.indices {
            for p in s.windows[w].panes.indices {
                s.windows[w].panes[p].claude?.status = nil
            }
        }
        return s
    }
}
