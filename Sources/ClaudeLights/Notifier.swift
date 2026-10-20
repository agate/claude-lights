import AppKit
import UserNotifications
import ClaudeLightsCore

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let soundsKey = "notificationSounds"
    static let bannersKey = "sessionBanners"
    /// Seconds an action banner stays in Notification Center after posting;
    /// long enough for the banner itself to finish showing.
    private static let infoLifetime: TimeInterval = 10

    /// User toggle from the tray menu (needs-you / done banners), independent
    /// of `soundsEnabled`; defaults to on.
    static var bannersEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: bannersKey) == nil
                ? true : UserDefaults.standard.bool(forKey: bannersKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: bannersKey) }
    }

    /// User toggle from the tray menu; defaults to on.
    static var soundsEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: soundsKey) == nil
                ? true : UserDefaults.standard.bool(forKey: soundsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: soundsKey) }
    }

    var onJump: ((String) -> Void)?
    var onInstallUpdate: (() -> Void)?
    private var authorized = false
    /// UNUserNotificationCenter traps when the process has no bundle (swift run).
    private let hasBundle = Bundle.main.bundleIdentifier != nil

    func setup() {
        guard hasBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    func notify(_ session: Session, description: String?) {
        post(session, title: "\(session.projectName) needs you",
             body: description ?? "Waiting for your input")
    }

    func notifyDone(_ session: Session, description: String?) {
        post(session, title: "\(session.projectName) is done",
             body: description ?? "Finished working")
    }

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

    /// Plain informational banner (save/restore results); not clickable.
    /// Removed from Notification Center shortly after, so action results
    /// don't pile up there.
    func notifyInfo(title: String, body: String) {
        guard hasBundle, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let id = "info-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.infoLifetime) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    private func post(_ session: Session, title: String, body: String) {
        // Stay silent when the user is already looking at this session's
        // window, or when sounds are toggled off in the menu.
        let silent = session.isOnScreen || !Notifier.soundsEnabled
        // Banners off: the sound still plays on its own.
        guard Notifier.bannersEnabled, hasBundle, authorized else {
            if !silent { NSSound(named: "Ping")?.play() }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        let subtitle = session.title ?? session.derivedName
        if !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        if !silent { content.sound = .default }
        content.userInfo = ["sessionId": session.id]
        let request = UNNotificationRequest(identifier: session.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.userInfo["update"] != nil {
            onInstallUpdate?()
        } else if let id = response.notification.request.content.userInfo["sessionId"] as? String {
            onJump?(id)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
