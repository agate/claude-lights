import Foundation
import ClaudeLightsCore

/// Fetches the account's usage limits every 5 minutes by asking Claude Code
/// itself (a `get_usage` control request over `claude -p` stream-json — no
/// model call, the OAuth token never leaves the CLI). Claude Code's own
/// `/usage` cache is too stale to read: it is only rewritten when `/usage`
/// opens. Silent: failures only go to usage.log, each distinct one once.
final class UsageMonitor {
    /// Main thread; only successful fetches are delivered, so the last good
    /// report stays on screen (fading as it goes stale) through failures.
    var onUpdate: ((UsageReport) -> Void)?
    /// Main thread; a fetch failed (ends the menu's refresh spinner).
    var onFailure: (() -> Void)?
    /// Main thread; Claude Code answered that it has no plan limits (signed
    /// out, or an API key) — drop the last report instead of showing it.
    var onSignedOut: (() -> Void)?

    /// Slow on purpose: the menu's refresh button covers "right now".
    static let interval: TimeInterval = 30 * 60
    private static let timeout: TimeInterval = 30

    private let queue = DispatchQueue(label: "me.honghao.claudelights.usage")
    private var timer: DispatchSourceTimer?
    private let log = ErrorLog(fileName: "usage.log")
    /// queue only.
    private var lastError: String?
    private var claudePath: String?
    private let env = ProcessInfo.processInfo.environment
    /// Demo hook: canned stream-json instead of the real account.
    private var demoFile: String? { env["CLAUDE_LIGHTS_DEMO_USAGE_FILE"] }
    /// Never the real account while the demo's synthetic registry is in use.
    private var disabled: Bool { demoFile == nil && env["CLAUDE_LIGHTS_SESSIONS_DIR"] != nil }

    func start() {
        guard !disabled else { return }
        // Dispatch timer, like the Poller's: a run-loop Timer gets stretched
        // by App Nap while the app sits in the background.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: Self.interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// The menu's refresh button. Serialized with the timer on `queue`.
    func refreshNow() {
        guard !disabled else { return }
        queue.async { [weak self] in self?.tick() }
    }

    private func tick() {
        if let demoFile { deliver(try? String(contentsOfFile: demoFile, encoding: .utf8)) }
        else { fetch() }
    }

    private func fetch() {
        if claudePath.map({ !FileManager.default.isExecutableFile(atPath: $0) }) ?? true {
            claudePath = BinaryLocator.locate("claude")
        }
        guard let claudePath else { return fail("claude not found") }
        let dir = URL(fileURLWithPath: UsageProbe.defaultDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = UsageProbe.arguments
        process.currentDirectoryURL = dir // lets the poller drop the probe's registry record
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return fail("launch failed: \(error.localizedDescription)") }
        try? input.fileHandleForWriting.write(contentsOf: Data(UsageProbe.request.utf8))
        try? input.fileHandleForWriting.close() // EOF: the CLI answers and exits
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        deliver(String(decoding: data, as: UTF8.self))
    }

    private func deliver(_ text: String?) {
        if let text, UsageReport.isSignedOut(streamJSON: text) {
            DispatchQueue.main.async { [weak self] in self?.onSignedOut?() }
            return fail("no plan limits: Claude Code is not signed in to a Claude subscription")
        }
        guard let text, let report = UsageReport.parse(streamJSON: text, fetchedAt: Date()) else {
            // Stable text (no stdout excerpt: it carries a fresh session id
            // each run), so a lasting failure is logged once.
            return fail("no usage in response")
        }
        lastError = nil
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(report) }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?() }
        guard message != lastError else { return }
        lastError = message
        log.log(message)
    }
}
