# Auto-Update Design

Date: 2026-07-17
Status: approved

## Goal

Claude Lights checks GitHub Releases for new versions, prompts the user
(menu item + one notification per version), and on click downloads,
installs, and relaunches — one-click update. The update engine is a
self-built lightweight implementation, but the design must make a future
switch to Sparkle 2 cheap.

## Decisions (from brainstorming)

- **Experience:** check-and-prompt with one-click install. Not fully
  silent, not notify-only.
- **Engine:** self-built (GitHub API), not Sparkle. Rationale: zero
  release-flow change, no framework dependency, no EdDSA key custody;
  Sparkle's edge-case handling is absorbed as explicit requirements below.
- **Check cadence:** ~10 s after launch, then every 24 h. Manual
  "Check for Updates…" menu item always available.
- **Prompt:** highlighted menu item ("⬆︎ Update to vX.Y.Z…") plus a
  system notification, at most once per version (persisted in
  UserDefaults).
- **Sparkle-swappable:** all UI talks to an `UpdaterEngine` protocol
  whose shape mirrors Sparkle's `SPUUpdater` surface.

## Architecture

### UpdaterEngine protocol (shell layer)

```swift
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
    func updaterWillInstall()   // about to swap + relaunch
}
```

`GitHubUpdater` implements it today. A future `SparkleUpdater` wraps
`SPUUpdater` behind the same protocol; swap is one constructor line in
`AppDelegate` plus bundle.sh changes (embed framework, add
`SUFeedURL`/`SUPublicEDKey` to Info.plist) and release-script additions
(sign zip, publish appcast). No UI code changes.

### Core (ClaudeLightsCore, unit-tested) — `UpdateCheck.swift`

Pure logic, no networking or file I/O:

- `AppVersion`: parse `"0.2.2"` / `"v0.2.2"` into numeric components;
  comparable segment-by-segment (missing segments = 0). Invalid → nil.
- `parseLatestRelease(json:)`: from a `releases/latest` response, extract
  tag name and the **first `.zip` asset** URL (never hardcode the asset
  filename — survives app/repo renames). Missing zip → nil.
- `UpdateDecision.shouldOffer(local:remote:)`: offer only when
  remote > local (no downgrades, no equal).
- `shouldNotify(version:lastNotified:)`: notify once per version.
- `isTranslocated(path:)`: true when the path contains
  `/AppTranslocation/`.

### Shell (ClaudeLights) — new files

- **`GitHubUpdater.swift`** (checker): timer (launch +10 s, then 24 h);
  GETs `https://api.github.com/repos/<owner>/<repo>/releases/latest`
  with a User-Agent header via URLSession; feeds the response through
  Core logic; reports via delegate. Repo owner/name live in one
  constant. Disabled entirely when not running from a bundled .app
  (development builds).
- **`UpdateInstaller.swift`**: given the zip URL —
  1. download to a temp directory;
  2. `ditto -x -k` to extract;
  3. locate the single `.app` in the extraction (never assume its name);
  4. validate: bundle identifier == `me.honghao.ClaudeLights`, and the
     declared executable exists;
  5. atomic swap: move the running app aside (sibling temp name), move
     the new app into the original path; on any failure move the old
     one back — the user's app is never left broken;
  6. `xattr -dr com.apple.quarantine` on the new bundle (belt and
     suspenders; our downloads are not quarantined anyway);
  7. relaunch: detached `sh -c 'sleep 1; open <path>'`, then terminate.
- **Menu integration** (`StatusItemController`): permanent
  "Check for Updates…" item; when an update is pending, a highlighted
  "⬆︎ Update to vX.Y.Z…" item appears near the top. Menu already
  rebuilds on open (NSMenuDelegate), so items are always current.
- **Notification**: reuse `Notifier`; clicking the update notification
  triggers install. Last-notified version stored in UserDefaults.

## Error handling

| Case | Behavior |
|---|---|
| App Translocation (running from ~/Downloads) | Never attempt swap; alert explains, offers "Open Release Page" and suggests moving to /Applications |
| No write permission to the app's parent directory | Fall back to opening the release page in the browser |
| Network/API failure or rate limit | Automatic checks fail silently (next cycle retries); manual checks show an alert |
| Zip contains no valid .app / wrong bundle id | Abort, keep the old version, offer the release page |
| Not running from a .app bundle (swift run / .build) | Updater disabled |
| Prerelease / draft releases | Excluded by the `releases/latest` endpoint; nothing to do |

## Release-flow contract (unchanged workflow)

- Keep tagging `vX.Y.Z` with `CFBundleShortVersionString` == `X.Y.Z`.
- Keep zipping with `ditto -c -k --keepParent` (top-level `.app` inside
  the zip).
- **Never change `CFBundleIdentifier`** (`me.honghao.ClaudeLights`) —
  display/app/repo names may change freely; the updater keys off the
  bundle id and picks assets/bundles by extension, not name.

## Testing

- **Core unit tests:** version parsing/comparison (equal, longer/shorter
  segment counts, `v` prefix, garbage input), release JSON parsing and
  zip-asset selection, notify-once logic, translocation detection.
- **Shell manual verification:** build with a lowered version, install
  to /Applications, exercise the real end-to-end flow against the live
  latest release (discover → notify → download → swap → relaunch);
  additionally verify the translocation and no-write-permission
  fallbacks.

## Known limitation (accepted)

The app is ad-hoc signed, so every update changes the code signature and
macOS may drop the AppleScript Automation grant (jump-to-tab silently
stops working until re-granted). Independent of update mechanism; the
real fix remains Developer ID signing + notarization.

## Sparkle migration checklist (future)

1. `swift package` dependency on Sparkle 2; embed the framework in
   bundle.sh and sign it.
2. Generate EdDSA keys (`generate_keys`); back up the private key.
3. Add `SUFeedURL` + `SUPublicEDKey` to Info.plist.
4. Release script: `sign_update` the zip, generate/publish appcast.xml
   at a stable URL.
5. Implement `SparkleUpdater: UpdaterEngine`; swap the constructor in
   AppDelegate; delete `GitHubUpdater`/`UpdateInstaller`.
