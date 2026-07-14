import Foundation

public enum TransitionDetector {
    /// Sessions that just turned red. `previous == nil` marks the first poll
    /// snapshot after launch: never notify then, to avoid a startup flood.
    public static func newlyRed(previous: [String: LightState]?,
                                current: [Session]) -> [Session] {
        guard let previous else { return [] }
        return current.filter { $0.light == .red && previous[$0.id] != .red }
    }

    /// Sessions that just finished working: they were busy (or waiting) and
    /// are now idle. New sessions appearing green never count.
    public static func newlyDone(previous: [String: LightState]?,
                                 current: [Session]) -> [Session] {
        guard let previous else { return [] }
        return current.filter { session in
            (session.light == .green || session.light == .greenSeen) &&
            (previous[session.id] == .yellow || previous[session.id] == .red)
        }
    }
}
