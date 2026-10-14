import Foundation
import ClaudeLightsCore

/// Talks to the default herdr server through its CLI.
///
/// Only the default session (`~/.config/herdr/herdr.sock`) is queried. The
/// socket check runs first so a machine without a running server never
/// spawns the CLI on every poll.
enum Herdr {
    static let path = BinaryLocator.locate("herdr")

    private static let socket = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".config/herdr/herdr.sock")

    static var available: Bool {
        path != nil && FileManager.default.fileExists(atPath: socket)
    }

    @discardableResult
    static func run(_ args: [String]) -> String? {
        guard available, let path else { return nil }
        return Shell.run(path, args)
    }

    static func agents() -> [HerdrAgent] {
        HerdrMapper.parseAgents(run(["agent", "list"]) ?? "")
    }

    /// ttys of the terminal tabs running an attached herdr client.
    static func clientTtys() -> [String] {
        guard available else { return [] }
        return HerdrMapper.parseClientTtys(
            Shell.run("/bin/ps", ["-ax", "-o", "tty=,command="]) ?? "")
    }
}
