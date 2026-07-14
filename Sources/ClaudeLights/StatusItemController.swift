import AppKit
import ServiceManagement
import ClaudeLightsCore

final class StatusItemController: NSObject {
    var onJump: ((Session) -> Void)?
    var onToggleBar: (() -> Void)?
    var isBarShown: () -> Bool = { true }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var sessions: [Session] = []
    private var spinTimer: Timer?
    private var spinAngle: CGFloat = 0
    private var aggregate: LightState = .gray

    func update(sessions: [Session], error: String?) {
        self.sessions = sessions
        aggregate = Aggregate.overall(sessions, hasError: error != nil)
        item.button?.toolTip = "Claude Lights"
        item.menu = buildMenu(error: error)
        refreshButtonImage()
        // Spin the menu-bar gear only while the aggregate is running, so the
        // timer sleeps whenever nothing is working.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if aggregate == .yellow && !reduceMotion {
            startSpinner()
        } else {
            stopSpinner()
        }
    }

    private func refreshButtonImage() {
        item.button?.image = StatusIcon.image(for: aggregate, diameter: 17, margin: 1,
                                              markRotation: spinAngle)
    }

    private func startSpinner() {
        guard spinTimer == nil else { return }
        // Match the floating bar: 360° every 2 s → 180°/s. At 15 fps that is
        // 12° per tick.
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.spinAngle = (self.spinAngle - 12).truncatingRemainder(dividingBy: 360)
            self.refreshButtonImage()
        }
        // .common so it keeps ticking while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        spinTimer = timer
    }

    private func stopSpinner() {
        spinTimer?.invalidate()
        spinTimer = nil
        if spinAngle != 0 { spinAngle = 0; refreshButtonImage() }
    }

    private func buildMenu(error: String?) -> NSMenu {
        let menu = NSMenu()
        if let error {
            menu.addItem(disabledItem(error))
        } else if sessions.isEmpty {
            menu.addItem(disabledItem("No Claude sessions"))
        }
        for (index, session) in sessions.enumerated() {
            let mi = NSMenuItem(title: session.summaryLine(),
                                action: #selector(jumpItem(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = index
            mi.image = StatusIcon.image(for: session.light)
            mi.toolTip = "\(session.cwd)\n\(session.derivedName)"
            menu.addItem(mi)
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Show Light Bar", action: #selector(toggleBar), keyEquivalent: "b")
        toggle.target = self
        toggle.state = isBarShown() ? .on : .off
        menu.addItem(toggle)

        let sounds = NSMenuItem(title: "Notification Sounds", action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self
        sounds.state = Notifier.soundsEnabled ? .on : .off
        menu.addItem(sounds)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        if Bundle.main.bundleIdentifier != nil {
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } // else: left targetless -> disabled under `swift run` (no bundle)
        menu.addItem(login)

        menu.addItem(NSMenuItem(title: "Quit Claude Lights",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    @objc private func jumpItem(_ sender: NSMenuItem) {
        guard sessions.indices.contains(sender.tag) else { return }
        onJump?(sessions[sender.tag])
    }

    @objc private func toggleBar() { onToggleBar?() }

    @objc private func toggleSounds() { Notifier.soundsEnabled.toggle() }

    /// Demo/testing hook: pops the tray menu open as if clicked.
    func openMenu() { item.button?.performClick(nil) }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }
}
