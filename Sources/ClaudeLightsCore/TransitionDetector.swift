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
    /// are now in the green family. New sessions appearing green never count,
    /// and settling within the family (greenBg → green when a background
    /// task ends without new output) never re-notifies.
    public static func newlyDone(previous: [String: LightState]?,
                                 current: [Session]) -> [Session] {
        guard let previous else { return [] }
        let family: Set<LightState> = [.green, .greenSeen, .greenBg]
        return current.filter { session in
            family.contains(session.light) &&
            (previous[session.id] == .yellow || previous[session.id] == .red)
        }
    }
}
