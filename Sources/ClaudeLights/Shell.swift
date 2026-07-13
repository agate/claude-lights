import Foundation

enum Shell {
    /// Runs a subprocess and returns stdout, or nil on any failure.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum BinaryLocator {
    /// GUI apps get a bare PATH; probe common install locations, then a login shell.
    static func locate(_ name: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/.claude/local/\(name)",
            "/usr/bin/\(name)",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        if let found = Shell.run("/bin/zsh", ["-lc", "command -v \(name)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !found.isEmpty {
            return found
        }
        return nil
    }
}
