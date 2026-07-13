import Foundation

public enum TransitionDetector {
    /// Sessions that just turned red. `previous == nil` marks the first poll
    /// snapshot after launch: never notify then, to avoid a startup flood.
    public static func newlyRed(previous: [String: LightState]?,
                                current: [Session]) -> [Session] {
        guard let previous else { return [] }
        return current.filter { $0.light == .red && previous[$0.id] != .red }
    }
}
