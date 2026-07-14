import Foundation
import CoreServices

/// Watches the session registry directory via FSEvents and fires whenever
/// any file inside changes. FSEvents' own latency parameter provides the
/// debounce — busy sessions rewrite their file constantly.
final class RegistryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init?(directory: URL, latency: TimeInterval = 0.5, onChange: @escaping () -> Void) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        self.onChange = onChange

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<RegistryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else { return nil }
        self.stream = stream
    }

    func start(on queue: DispatchQueue) {
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
