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
