# Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Lights checks GitHub Releases for new versions, prompts via menu item + notification, and installs/relaunches on one click — behind a Sparkle-swappable `UpdaterEngine` protocol.

**Architecture:** Pure decision logic (version compare, release JSON parsing, notify-once, translocation detection) lives in `ClaudeLightsCore` with unit tests. The AppKit shell gets `GitHubUpdater` (periodic checker) and `UpdateInstaller` (download → validate → atomic swap → relaunch), both hidden behind an `UpdaterEngine` protocol so a future `SparkleUpdater` is a drop-in.

**Tech Stack:** Swift 5.9 / SwiftPM, XCTest, URLSession, `/usr/bin/ditto`, `/usr/bin/xattr`. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-07-17-auto-update-design.md`

## Global Constraints

- Bundle identifier is `me.honghao.ClaudeLights` — the installer validates against exactly this string; never change it.
- GitHub repo constant: `agate/claude-lights`.
- Never hardcode the zip asset filename or the `.app` name — pick by extension.
- Updates offered only when remote > local (no downgrade, no equal).
- Updater fully disabled when `Bundle.main.bundleIdentifier == nil` (i.e. `swift run` dev builds — same guard the codebase already uses in `Notifier`/`StatusItemController`).
- Core target must stay AppKit-free.
- All user-facing strings in English.
- Run tests with `swift test` from the repo root; must stay green.

---

### Task 1: Core — `AppVersion` parse & compare

**Files:**
- Create: `Sources/ClaudeLightsCore/UpdateCheck.swift`
- Create: `Tests/ClaudeLightsCoreTests/UpdateCheckTests.swift`

**Interfaces:**
- Produces: `public struct AppVersion: Comparable, Equatable` with `init?(_ string: String)`; parses `"0.2.2"` and `"v0.2.2"`; segment-wise numeric compare, missing segments count as 0.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/ClaudeLightsCoreTests/UpdateCheckTests.swift
import XCTest
@testable import ClaudeLightsCore

final class UpdateCheckTests: XCTestCase {
    // MARK: AppVersion

    func testParsePlain() {
        XCTAssertEqual(AppVersion("0.2.2")?.components, [0, 2, 2])
    }

    func testParseVPrefix() {
        XCTAssertEqual(AppVersion("v0.3.0")?.components, [0, 3, 0])
    }

    func testParseGarbage() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("abc"))
        XCTAssertNil(AppVersion("1.2.beta"))
        XCTAssertNil(AppVersion("v"))
    }

    func testCompareBasic() {
        XCTAssertTrue(AppVersion("0.2.2")! < AppVersion("0.3.0")!)
        XCTAssertTrue(AppVersion("0.9.9")! < AppVersion("1.0.0")!)
        XCTAssertFalse(AppVersion("0.3.0")! < AppVersion("0.2.2")!)
    }

    func testCompareDifferentLengths() {
        // "1.0" == "1" semantically; neither is less.
        XCTAssertFalse(AppVersion("1.0")! < AppVersion("1")!)
        XCTAssertFalse(AppVersion("1")! < AppVersion("1.0")!)
        XCTAssertEqual(AppVersion("1.0")!, AppVersion("1")!)
        XCTAssertTrue(AppVersion("1")! < AppVersion("1.0.1")!)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UpdateCheckTests 2>&1 | tail -5`
Expected: compile error — `cannot find 'AppVersion' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/ClaudeLightsCore/UpdateCheck.swift
import Foundation

/// A dotted numeric version like "0.2.2"; accepts an optional "v" prefix
/// (release tags are "vX.Y.Z"). Missing segments compare as 0, so 1.0 == 1.
public struct AppVersion: Comparable {
    public let components: [Int]

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        guard !s.isEmpty else { return nil }
        var nums: [Int] = []
        for part in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(part), n >= 0 else { return nil }
            nums.append(n)
        }
        self.components = nums
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.components.count, rhs.components.count) {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    // Memberwise equality would make [1] != [1, 0]; define it via ordering.
    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UpdateCheckTests 2>&1 | tail -3`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeLightsCore/UpdateCheck.swift Tests/ClaudeLightsCoreTests/UpdateCheckTests.swift
git commit -m "feat: add AppVersion parse/compare for update checks"
```

---

### Task 2: Core — `ReleaseParser` for GitHub `releases/latest`

**Files:**
- Modify: `Sources/ClaudeLightsCore/UpdateCheck.swift` (append)
- Modify: `Tests/ClaudeLightsCoreTests/UpdateCheckTests.swift` (append)

**Interfaces:**
- Produces: `public struct ReleaseInfo: Equatable { let tag, zipURL, htmlURL: String }` and `public enum ReleaseParser { static func parse(_ json: String) -> ReleaseInfo? }`. Picks the **first `.zip` asset** (case-insensitive); returns nil when there is none.

- [ ] **Step 1: Write the failing tests** (append inside `UpdateCheckTests`)

```swift
    // MARK: ReleaseParser

    // Shape of api.github.com/repos/<owner>/<repo>/releases/latest
    let releaseFixture = """
    {"tag_name":"v0.3.0","html_url":"https://github.com/agate/claude-lights/releases/tag/v0.3.0",
     "draft":false,"prerelease":false,
     "assets":[
       {"name":"README.txt","browser_download_url":"https://example.com/README.txt"},
       {"name":"0.3.0.zip","browser_download_url":"https://github.com/agate/claude-lights/releases/download/v0.3.0/0.3.0.zip"},
       {"name":"other.zip","browser_download_url":"https://example.com/other.zip"}
     ]}
    """

    func testParseRelease() {
        let r = ReleaseParser.parse(releaseFixture)
        XCTAssertEqual(r?.tag, "v0.3.0")
        XCTAssertEqual(r?.zipURL,
            "https://github.com/agate/claude-lights/releases/download/v0.3.0/0.3.0.zip")
        XCTAssertEqual(r?.htmlURL,
            "https://github.com/agate/claude-lights/releases/tag/v0.3.0")
    }

    func testParseReleaseNoZipAsset() {
        let json = """
        {"tag_name":"v0.3.0","html_url":"https://x","assets":[{"name":"a.txt","browser_download_url":"https://x/a.txt"}]}
        """
        XCTAssertNil(ReleaseParser.parse(json))
    }

    func testParseReleaseGarbage() {
        XCTAssertNil(ReleaseParser.parse("not json"))
        XCTAssertNil(ReleaseParser.parse("{}"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UpdateCheckTests 2>&1 | tail -5`
Expected: compile error — `cannot find 'ReleaseParser' in scope`.

- [ ] **Step 3: Write the implementation** (append to `UpdateCheck.swift`)

```swift
/// The latest published release: its tag, first .zip asset, and web page.
public struct ReleaseInfo: Equatable {
    public let tag: String
    public let zipURL: String
    public let htmlURL: String

    public init(tag: String, zipURL: String, htmlURL: String) {
        self.tag = tag
        self.zipURL = zipURL
        self.htmlURL = htmlURL
    }
}

public enum ReleaseParser {
    /// Parses a GitHub `releases/latest` response. The zip asset is picked
    /// by extension, never by name, so app/repo renames don't break updates.
    public static func parse(_ json: String) -> ReleaseInfo? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let htmlURL = obj["html_url"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        let zip = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }
        guard let zipURL = zip?["browser_download_url"] as? String else { return nil }
        return ReleaseInfo(tag: tag, zipURL: zipURL, htmlURL: htmlURL)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UpdateCheckTests 2>&1 | tail -3`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeLightsCore/UpdateCheck.swift Tests/ClaudeLightsCoreTests/UpdateCheckTests.swift
git commit -m "feat: parse GitHub latest-release JSON, pick zip asset by extension"
```

---

### Task 3: Core — `UpdatePolicy` (offer / notify-once / translocation)

**Files:**
- Modify: `Sources/ClaudeLightsCore/UpdateCheck.swift` (append)
- Modify: `Tests/ClaudeLightsCoreTests/UpdateCheckTests.swift` (append)

**Interfaces:**
- Produces: `public enum UpdatePolicy` with
  - `static func shouldOffer(local: String, remoteTag: String) -> Bool`
  - `static func shouldNotify(version: String, lastNotified: String?) -> Bool`
  - `static func isTranslocated(path: String) -> Bool`

- [ ] **Step 1: Write the failing tests** (append inside `UpdateCheckTests`)

```swift
    // MARK: UpdatePolicy

    func testShouldOfferOnlyWhenNewer() {
        XCTAssertTrue(UpdatePolicy.shouldOffer(local: "0.2.2", remoteTag: "v0.3.0"))
        XCTAssertFalse(UpdatePolicy.shouldOffer(local: "0.3.0", remoteTag: "v0.3.0"))
        XCTAssertFalse(UpdatePolicy.shouldOffer(local: "0.3.1", remoteTag: "v0.3.0")) // no downgrade
    }

    func testShouldOfferUnparsableIsFalse() {
        XCTAssertFalse(UpdatePolicy.shouldOffer(local: "0.2.2", remoteTag: "nightly"))
        XCTAssertFalse(UpdatePolicy.shouldOffer(local: "", remoteTag: "v0.3.0"))
    }

    func testShouldNotifyOncePerVersion() {
        XCTAssertTrue(UpdatePolicy.shouldNotify(version: "v0.3.0", lastNotified: nil))
        XCTAssertTrue(UpdatePolicy.shouldNotify(version: "v0.3.0", lastNotified: "v0.2.9"))
        XCTAssertFalse(UpdatePolicy.shouldNotify(version: "v0.3.0", lastNotified: "v0.3.0"))
    }

    func testIsTranslocated() {
        XCTAssertTrue(UpdatePolicy.isTranslocated(
            path: "/private/var/folders/ab/xyz/T/AppTranslocation/1234-ABCD/d/ClaudeLights.app"))
        XCTAssertFalse(UpdatePolicy.isTranslocated(path: "/Applications/ClaudeLights.app"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UpdateCheckTests 2>&1 | tail -5`
Expected: compile error — `cannot find 'UpdatePolicy' in scope`.

- [ ] **Step 3: Write the implementation** (append to `UpdateCheck.swift`)

```swift
public enum UpdatePolicy {
    /// Offer only strict upgrades; unparsable versions never offer.
    public static func shouldOffer(local: String, remoteTag: String) -> Bool {
        guard let l = AppVersion(local), let r = AppVersion(remoteTag) else { return false }
        return r > l
    }

    /// One notification per version, ever.
    public static func shouldNotify(version: String, lastNotified: String?) -> Bool {
        version != lastNotified
    }

    /// Gatekeeper app translocation runs the app from a read-only mount;
    /// self-replacement is impossible there.
    public static func isTranslocated(path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -3`
Expected: all suites pass, `0 failures` (full run to catch regressions).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeLightsCore/UpdateCheck.swift Tests/ClaudeLightsCoreTests/UpdateCheckTests.swift
git commit -m "feat: add UpdatePolicy — offer, notify-once, translocation detection"
```

---

### Task 4: Shell — `UpdaterEngine` protocol + `GitHubUpdater` checker

**Files:**
- Create: `Sources/ClaudeLights/UpdaterEngine.swift`
- Create: `Sources/ClaudeLights/GitHubUpdater.swift`

**Interfaces:**
- Consumes: `ReleaseParser.parse(_:)`, `UpdatePolicy.shouldOffer(local:remoteTag:)` from Core.
- Produces: `protocol UpdaterEngine` / `protocol UpdaterEngineDelegate` (shape mirrors Sparkle's `SPUUpdater` so a future `SparkleUpdater` is drop-in), `final class GitHubUpdater: UpdaterEngine` with `var pending: ReleaseInfo?`. Task 5 provides `UpdateInstaller.install(from:completion:)` which `installPendingUpdate()` calls — stub the call in this task with a `// wired in UpdateInstaller task` comment removed in Task 5? **No** — to keep every commit compiling, this task creates `GitHubUpdater` *without* the installer reference; `installPendingUpdate()` only fires `updaterWillInstall()` for now and Task 5 completes it.

No unit tests (shell layer is verified by running, per project convention); the gate is a clean build.

- [ ] **Step 1: Create `UpdaterEngine.swift`**

```swift
// Sources/ClaudeLights/UpdaterEngine.swift
import Foundation

/// Update engine abstraction. Shaped after Sparkle's SPUUpdater surface so
/// switching to Sparkle later is a constructor swap (see the design spec's
/// migration checklist); UI code must only ever talk to this protocol.
protocol UpdaterEngine: AnyObject {
    var delegate: UpdaterEngineDelegate? { get set }
    func startPeriodicChecks()
    func checkForUpdates(userInitiated: Bool)
    func installPendingUpdate()
}

protocol UpdaterEngineDelegate: AnyObject {
    func updaterFoundUpdate(version: String)
    func updaterIsUpToDate(userInitiated: Bool)
    func updaterFailed(error: String, userInitiated: Bool)
    /// The engine is about to replace the bundle and relaunch.
    func updaterWillInstall()
}
```

- [ ] **Step 2: Create `GitHubUpdater.swift`**

```swift
// Sources/ClaudeLights/GitHubUpdater.swift
import Foundation
import ClaudeLightsCore

/// Self-built engine: polls GitHub's releases/latest endpoint. All delegate
/// callbacks arrive on the main queue.
final class GitHubUpdater: UpdaterEngine {
    static let repo = "agate/claude-lights"

    weak var delegate: UpdaterEngineDelegate?
    private(set) var pending: ReleaseInfo?
    private var timer: Timer?

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
        guard pending != nil else { return }
        delegate?.updaterWillInstall()
        // Task "UpdateInstaller" completes this method.
    }
}
```

- [ ] **Step 3: Verify it builds**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeLights/UpdaterEngine.swift Sources/ClaudeLights/GitHubUpdater.swift
git commit -m "feat: add UpdaterEngine protocol and GitHubUpdater release checker"
```

---

### Task 5: Shell — `UpdateInstaller` (download → validate → swap → relaunch)

**Files:**
- Create: `Sources/ClaudeLights/UpdateInstaller.swift`
- Modify: `Sources/ClaudeLights/GitHubUpdater.swift` (complete `installPendingUpdate()`)

**Interfaces:**
- Consumes: `ReleaseInfo`, `UpdatePolicy.isTranslocated(path:)` from Core; `Shell.run(_:_:)` from the shell target.
- Produces: `final class UpdateInstaller` with `func install(from release: ReleaseInfo, completion: @escaping (String?) -> Void)` — completion gets an error message on failure (main queue); on success the process relaunches and exits. Handled fallbacks (translocation, no write permission) complete with `nil` after showing their own alert.

- [ ] **Step 1: Create `UpdateInstaller.swift`**

```swift
// Sources/ClaudeLights/UpdateInstaller.swift
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
```

- [ ] **Step 2: Complete `GitHubUpdater.installPendingUpdate()`**

In `Sources/ClaudeLights/GitHubUpdater.swift`, add a stored property and replace the method:

```swift
    private let installer = UpdateInstaller()
```

```swift
    func installPendingUpdate() {
        guard let pending else { return }
        delegate?.updaterWillInstall()
        installer.install(from: pending) { [weak self] errorMessage in
            if let errorMessage {
                self?.delegate?.updaterFailed(error: errorMessage, userInitiated: true)
            }
        }
    }
```

- [ ] **Step 3: Verify it builds**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeLights/UpdateInstaller.swift Sources/ClaudeLights/GitHubUpdater.swift
git commit -m "feat: add UpdateInstaller — download, validate, atomic swap, relaunch"
```

---

### Task 6: Shell — UI wiring (menu, notification, AppDelegate)

**Files:**
- Modify: `Sources/ClaudeLights/StatusItemController.swift`
- Modify: `Sources/ClaudeLights/Notifier.swift`
- Modify: `Sources/ClaudeLights/AppDelegate.swift`

**Interfaces:**
- Consumes: `UpdaterEngine`/`UpdaterEngineDelegate`, `GitHubUpdater`, `UpdatePolicy.shouldNotify(version:lastNotified:)`.
- Produces: user-visible behavior — "Check for Updates…" menu item (always, disabled under swift run), "⬆︎ Update to vX.Y.Z…" item when pending, one notification per version whose click installs.

- [ ] **Step 1: Extend `StatusItemController`**

Add three properties next to `onJump`/`onToggleBar` (top of the class):

```swift
    var onCheckForUpdates: (() -> Void)?
    var onInstallUpdate: (() -> Void)?
    /// Set when an update is pending, e.g. "v0.3.0"; menu rebuilds on open.
    var pendingUpdateVersion: String?
```

In `populate(_:error:)`, insert at the very top of the method (before the `if let error` line):

```swift
        if let v = pendingUpdateVersion {
            let up = NSMenuItem(title: "⬆︎ Update to \(v)…",
                                action: #selector(installUpdate), keyEquivalent: "")
            up.target = self
            menu.addItem(up)
            menu.addItem(.separator())
        }
```

After the `login` item is added (before the Quit item), add:

```swift
        let check = NSMenuItem(title: "Check for Updates…",
                               action: #selector(checkForUpdates), keyEquivalent: "")
        if Bundle.main.bundleIdentifier != nil {
            check.target = self
        } // else: left targetless -> disabled under `swift run` (no bundle)
        menu.addItem(check)
```

Add the actions next to `toggleBar`:

```swift
    @objc private func installUpdate() { onInstallUpdate?() }

    @objc private func checkForUpdates() { onCheckForUpdates?() }
```

- [ ] **Step 2: Extend `Notifier` with an update notification**

Add next to `onJump`:

```swift
    var onInstallUpdate: (() -> Void)?
```

Add after `notifyDone`:

```swift
    func notifyUpdate(version: String) {
        guard hasBundle, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Claude Lights \(version) is available"
        content.body = "Click to update and relaunch."
        if Notifier.soundsEnabled { content.sound = .default }
        content.userInfo = ["update": version]
        let request = UNNotificationRequest(identifier: "update-\(version)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
```

In `userNotificationCenter(_:didReceive:withCompletionHandler:)`, route update clicks before the session lookup:

```swift
        if response.notification.request.content.userInfo["update"] != nil {
            onInstallUpdate?()
        } else if let id = response.notification.request.content.userInfo["sessionId"] as? String {
            onJump?(id)
        }
        completionHandler()
```

(Replace the existing `if let id …` block with the above.)

- [ ] **Step 3: Wire everything in `AppDelegate`**

Add a property next to `jumper`/`notifier`:

```swift
    private let updater: UpdaterEngine = GitHubUpdater()
```

Add at the end of `applicationDidFinishLaunching` (after the demo-hook block):

```swift
        updater.delegate = self
        statusController.onCheckForUpdates = { [weak self] in
            self?.updater.checkForUpdates(userInitiated: true)
        }
        statusController.onInstallUpdate = { [weak self] in
            self?.updater.installPendingUpdate()
        }
        notifier.onInstallUpdate = { [weak self] in
            self?.updater.installPendingUpdate()
        }
        updater.startPeriodicChecks()
```

Add at the bottom of the file:

```swift
extension AppDelegate: UpdaterEngineDelegate {
    private static let lastNotifiedKey = "lastNotifiedUpdateVersion"

    func updaterFoundUpdate(version: String) {
        statusController.pendingUpdateVersion = version
        let last = UserDefaults.standard.string(forKey: Self.lastNotifiedKey)
        if UpdatePolicy.shouldNotify(version: version, lastNotified: last) {
            UserDefaults.standard.set(version, forKey: Self.lastNotifiedKey)
            notifier.notifyUpdate(version: version)
        }
    }

    func updaterIsUpToDate(userInitiated: Bool) {
        guard userInitiated else { return }
        updateAlert(title: "You're up to date",
                    text: "This is the latest version of Claude Lights.")
    }

    func updaterFailed(error: String, userInitiated: Bool) {
        guard userInitiated else { return } // background checks fail silently
        updateAlert(title: "Update check failed", text: error)
    }

    func updaterWillInstall() {}

    private func updateAlert(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
```

- [ ] **Step 4: Verify build and full test suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: `Build complete!` and `0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeLights/StatusItemController.swift Sources/ClaudeLights/Notifier.swift Sources/ClaudeLights/AppDelegate.swift
git commit -m "feat: wire auto-update into menu, notifications, and app lifecycle"
```

---

### Task 7: Verification + docs

**Files:**
- Modify: `CLAUDE.md` (one bullet about the updater)

- [ ] **Step 1: Full test suite**

Run: `swift test 2>&1 | tail -3`
Expected: `0 failures`.

- [ ] **Step 2: Build the app bundle**

Run: `scripts/bundle.sh 2>&1 | tail -2`
Expected: `Built build/ClaudeLights.app`.

- [ ] **Step 3: End-to-end check against the live release**

The installed version (0.2.2) equals the latest release, so verify the
"up to date" path plus the discovery path with a lowered local version:

```bash
# Lower the built app's version so the live v0.2.2 release counts as an update.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.0.1" \
  build/ClaudeLights.app/Contents/Info.plist
codesign --force -s - build/ClaudeLights.app
open build/ClaudeLights.app
```

Then, by hand: wait ~10 s → the menu shows "⬆︎ Update to v0.2.2…" and a
notification appears → click the menu item → the app replaces itself in
`build/` and relaunches → menu shows version-appropriate state ("Check for
Updates…" reports up to date). This exercises download, validation, swap,
and relaunch against the real release asset.

Also verify: with the normal 0.2.2 build, "Check for Updates…" shows the
"You're up to date" alert.

- [ ] **Step 4: Document in CLAUDE.md**

Add under "Hard-won facts":

```markdown
- **Auto-update:** `GitHubUpdater` polls `releases/latest` (launch + 24 h),
  UI talks only to the `UpdaterEngine` protocol (Sparkle-swappable, see
  docs/superpowers/specs/2026-07-17-auto-update-design.md). Installer picks
  zip/app by extension, validates bundle id, swaps with rollback. Keep tags
  `vX.Y.Z` == `CFBundleShortVersionString`, zip via `ditto --keepParent`.
```

- [ ] **Step 5: Rebuild clean and commit**

```bash
scripts/bundle.sh >/dev/null 2>&1   # restore the un-tampered 0.2.2 bundle
git add CLAUDE.md
git commit -m "docs: note auto-update architecture in CLAUDE.md"
```
