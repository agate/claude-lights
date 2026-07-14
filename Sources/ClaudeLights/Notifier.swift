import AppKit
import UserNotifications
import ClaudeLightsCore

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let soundsKey = "notificationSounds"

    /// User toggle from the tray menu; defaults to on.
    static var soundsEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: soundsKey) == nil
                ? true : UserDefaults.standard.bool(forKey: soundsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: soundsKey) }
    }

    var onJump: ((String) -> Void)?
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

    private func post(_ session: Session, title: String, body: String) {
        // Stay silent when the user is already looking at this session's
        // window, or when sounds are toggled off in the menu.
        let silent = session.isOnScreen || !Notifier.soundsEnabled
        guard hasBundle, authorized else {
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
        if let id = response.notification.request.content.userInfo["sessionId"] as? String {
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
