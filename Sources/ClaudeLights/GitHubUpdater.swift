import Foundation
import ClaudeLightsCore

/// Self-built engine: polls GitHub's releases/latest endpoint. All delegate
/// callbacks arrive on the main queue.
final class GitHubUpdater: UpdaterEngine {
    static let repo = "agate/claude-lights"

    weak var delegate: UpdaterEngineDelegate?
    private(set) var pending: ReleaseInfo?
    private var timer: Timer?
    private let installer = UpdateInstaller()

    private var localVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// No bundle (swift run) means nothing on disk to replace.
    var isEnabled: Bool { Bundle.main.bundleIdentifier != nil && localVersion != nil }

    func startPeriodicChecks() {
        guard isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.checkForUpdates(userInitiated: false)
        }
        let t = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkForUpdates(userInitiated: false)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func checkForUpdates(userInitiated: Bool) {
        guard isEnabled, let local = localVersion else {
            delegate?.updaterFailed(error: "Updates are disabled in development builds.",
                                    userInitiated: userInitiated)
            return
        }
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("ClaudeLights", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data,
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let body = String(data: data, encoding: .utf8),
                      let release = ReleaseParser.parse(body) else {
                    self.delegate?.updaterFailed(
                        error: error?.localizedDescription ?? "Could not reach GitHub.",
                        userInitiated: userInitiated)
                    return
                }
                if UpdatePolicy.shouldOffer(local: local, remoteTag: release.tag) {
                    self.pending = release
                    self.delegate?.updaterFoundUpdate(version: release.tag)
                } else {
                    self.delegate?.updaterIsUpToDate(userInitiated: userInitiated)
                }
            }
        }.resume()
    }

    func installPendingUpdate() {
        guard let pending else { return }
        delegate?.updaterWillInstall()
        installer.install(from: pending) { [weak self] errorMessage in
            if let errorMessage {
                self?.delegate?.updaterFailed(error: errorMessage, userInitiated: true)
            }
        }
    }
}
