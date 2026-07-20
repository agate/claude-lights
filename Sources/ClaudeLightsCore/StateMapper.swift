import Foundation

public enum StateMapper {
    /// Maps registry status/state fields to a traffic light.
    /// Verified values on 2.1.207: status "busy"/"idle", state "done".
    /// Waiting-state value is matched by substring until verified live (Task 13).
    public static func light(status: String?, state: String?) -> LightState {
        let s = (status ?? "").lowercased()
        let redMarkers = ["wait", "input", "permission", "attention", "block"]
        if redMarkers.contains(where: { s.contains($0) }) { return .red }
        if s == "busy" || s == "working" || s == "running" { return .yellow }
        // Verified live on 2.1.212: "shell" = main thread quiet, background
        // task still running (foreground commands report "busy").
        if s == "shell" { return .greenBg }
        if s == "idle" || (state ?? "").lowercased() == "done" { return .green }
        return .gray
    }
}
