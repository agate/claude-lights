import Foundation
import SystemConfiguration
import ClaudeLightsCore

enum SnapshotStoreError: LocalizedError {
    case iCloudUnavailable
    var errorDescription: String? { "iCloud Drive is not available" }
}

/// Snapshot files in iCloud Drive, one folder per Mac. No local fallback:
/// without iCloud Drive every call throws `iCloudUnavailable`.
final class SnapshotStore {
    static let defaultCloudDocs = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")

    static func currentComputerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?)
            ?? ProcessInfo.processInfo.hostName
    }

    private let cloudDocs: URL
    let folder: URL

    init(cloudDocs: URL = SnapshotStore.defaultCloudDocs,
         computerName: String = SnapshotStore.currentComputerName()) {
        self.cloudDocs = cloudDocs
        folder = cloudDocs.appendingPathComponent("ClaudeLights/sessions", isDirectory: true)
            .appendingPathComponent(SnapshotCodec.folderName(computerName: computerName),
                                    isDirectory: true)
    }

    private func ensureFolder() throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cloudDocs.path, isDirectory: &isDir),
              isDir.boolValue else { throw SnapshotStoreError.iCloudUnavailable }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Every snapshot in this Mac's folder. Evicted iCloud placeholders
    /// (`.<file>.icloud`) get a download request and show as downloading.
    func list() throws -> [SnapshotListing] {
        try ensureFolder()
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        var out: [SnapshotListing] = []
        for file in files {
            if let name = SnapshotCodec.sessionName(fromFileName: file) {
                do { out.append(.ready(try read(name: name))) } catch { out.append(.unreadable(name)) }
            } else if file.hasPrefix("."), file.hasSuffix(".json.icloud"),
                      let name = SnapshotCodec.sessionName(
                        fromFileName: String(file.dropFirst().dropLast(".icloud".count))) {
                let real = folder.appendingPathComponent(SnapshotCodec.fileName(for: name))
                try? FileManager.default.startDownloadingUbiquitousItem(at: real)
                out.append(.downloading(name))
            }
        }
        return out
    }

    func read(name: String) throws -> SnapshotFile {
        let url = folder.appendingPathComponent(SnapshotCodec.fileName(for: name))
        var data: Data?
        var coordError: NSError?
        var readError: Error?
        // Coordinated read: waits for iCloud to finish writing the file.
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            do { data = try Data(contentsOf: u) } catch { readError = error }
        }
        if let coordError { throw coordError }
        if let readError { throw readError }
        var file = try SnapshotCodec.decode(data ?? Data())
        file.session.name = name  // File name wins, so a hand-copied file's menu label and tmux name match.
        return file
    }

    /// Atomic replace of `<name>.json`.
    func write(_ file: SnapshotFile) throws {
        try ensureFolder()
        let url = folder.appendingPathComponent(SnapshotCodec.fileName(for: file.session.name))
        let data = try SnapshotCodec.encode(file)
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &coordError) { u in
            do { try data.write(to: u, options: .atomic) } catch { writeError = error }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }
}
