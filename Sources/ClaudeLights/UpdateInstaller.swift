import AppKit
import ClaudeLightsCore

/// Replaces the running app bundle with a downloaded release and relaunches.
/// Every unrecoverable path falls back to the release web page so the user
/// can always update by hand.
final class UpdateInstaller {
    private let expectedBundleID = "me.honghao.ClaudeLights"

    func install(from release: ReleaseInfo, completion: @escaping (String?) -> Void) {
        let appURL = Bundle.main.bundleURL

        // Translocated = running read-only from a random path; we cannot
        // replace ourselves there.
        if UpdatePolicy.isTranslocated(path: appURL.path) {
            offerReleasePage(release, message:
                "Claude Lights is running from a temporary location. "
                + "Move it to /Applications first, then update.")
            completion(nil)
            return
        }
        let parent = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            offerReleasePage(release, message:
                "No permission to replace the app in \(parent.path). "
                + "Please update manually.")
            completion(nil)
            return
        }
        guard let zipURL = URL(string: release.zipURL) else {
            completion("The release has a malformed download URL.")
            return
        }

        var request = URLRequest(url: zipURL)
        request.setValue("ClaudeLights", forHTTPHeaderField: "User-Agent")
        URLSession.shared.downloadTask(with: request) { [weak self] tmp, _, error in
            // The handler's temp file dies when this closure returns —
            // claim it before hopping queues.
            let fm = FileManager.default
            var claimed: URL?
            if let tmp {
                let dest = fm.temporaryDirectory
                    .appendingPathComponent("ClaudeLightsUpdate-\(UUID().uuidString).zip")
                claimed = (try? fm.moveItem(at: tmp, to: dest)) != nil ? dest : nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard let zip = claimed else {
                    completion(error?.localizedDescription ?? "The download failed.")
                    return
                }
                defer { try? fm.removeItem(at: zip) }
                completion(self.installDownloaded(zipAt: zip, over: appURL))
            }
        }.resume()
    }

    /// Returns an error message, or nil after kicking off the relaunch.
    private func installDownloaded(zipAt zip: URL, over appURL: URL) -> String? {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("ClaudeLightsUpdate-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            return "Could not create a working directory: \(error.localizedDescription)"
        }
        guard Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) != nil else {
            return "Could not extract the update archive."
        }
        // Find the .app by extension — its name may have changed since this
        // version shipped.
        guard let newApp = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else {
            return "The update archive did not contain an app."
        }
        guard let bundle = Bundle(url: newApp),
              bundle.bundleIdentifier == expectedBundleID,
              let exe = bundle.executableURL, fm.isExecutableFile(atPath: exe.path) else {
            return "The downloaded app failed validation."
        }
        // Our download carries no quarantine flag, but strip defensively.
        Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        // Swap: old aside → new in → drop old. Any failure rolls back so the
        // user's app is never left broken.
        let parent = appURL.deletingLastPathComponent()
        let aside = parent.appendingPathComponent(".ClaudeLights-old-\(UUID().uuidString)")
        let dest = parent.appendingPathComponent(newApp.lastPathComponent)
        do {
            try fm.moveItem(at: appURL, to: aside)
        } catch {
            return "Could not move the current app aside: \(error.localizedDescription)"
        }
        if dest != appURL, fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: dest) // stale copy under the new name
        }
        do {
            try fm.moveItem(at: newApp, to: dest)
        } catch {
            try? fm.moveItem(at: aside, to: appURL) // roll back
            return "Could not install the new app: \(error.localizedDescription)"
        }
        try? fm.removeItem(at: aside)
        relaunch(dest)
        return nil
    }

    private func relaunch(_ appURL: URL) {
        // Detached child outlives us; the 1 s sleep lets this process exit
        // before `open` starts the new one.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(appURL.path)\""]
        try? p.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private func offerReleasePage(_ release: ReleaseInfo, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Can't update automatically"
        alert.informativeText = message
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: release.htmlURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
