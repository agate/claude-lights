import Foundation
import ClaudeLightsCore

/// Append-only error log for background work that must not notify, e.g.
/// auto-save. Lives in ~/Library/Logs (shown by Console.app); rotates to a
/// single `.1` file at 1 MB.
final class ErrorLog {
    static let maxBytes: UInt64 = 1_000_000

    let url: URL
    private let queue = DispatchQueue(label: "ClaudeLights.errorlog")

    init(fileName: String) {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeLights", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    func log(_ message: String) {
        let line = "\(SnapshotCodec.timestamp(Date())) \(message)\n"
        queue.async { [url] in
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64,
               size >= Self.maxBytes {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        }
    }
}
