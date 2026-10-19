import AppKit
import ServiceManagement
import ClaudeLightsCore

final class StatusItemController: NSObject {
    var onJump: ((Session) -> Void)?
    /// Session to close (the ⌥ alternate of a session row); confirms first.
    var onCloseSession: ((Session) -> Void)?
    var onToggleBar: (() -> Void)?
    var isBarShown: () -> Bool = { true }
    var onCheckForUpdates: (() -> Void)?
    var onSaveSessions: (() -> Void)?
    /// Snapshot names to restore; nil means "Restore All" (resolved off the main thread).
    var onRestore: (([String]?) -> Void)?
    var onMenuWillOpen: (() -> Void)?
    /// Saved snapshot to delete (the ⌥ alternate of a Restore row).
    var onDeleteSnapshot: ((String) -> Void)?
    var snapshotMenuEntries: () -> [SnapshotMenuEntry] = { [] }
    /// Same as the three above, for the Restore ▸ Auto Saved submenu.
    var onRestoreAuto: (([String]?) -> Void)?
    var onDeleteAutoSnapshot: ((String) -> Void)?
    var autoSnapshotMenuEntries: () -> [SnapshotMenuEntry] = { [] }
    var isAutoSaveOn: () -> Bool = { true }
    var onToggleAutoSave: (() -> Void)?
    var onInstallUpdate: (() -> Void)?
    /// Set when an update is pending, e.g. "v0.3.0"; menu rebuilds on open.
    var pendingUpdateVersion: String?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var sessions: [Session] = []
    private var lastError: String?
    private var spinTimer: Timer?
    private var spinAngle: CGFloat = 0
    private var aggregate: LightState = .gray

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self // rebuilt on open so toggle states are always live
        item.menu = menu
    }

    func update(sessions: [Session], error: String?) {
        self.sessions = sessions
        self.lastError = error
        aggregate = Aggregate.overall(sessions, hasError: error != nil)
        item.button?.toolTip = "Claude Lights"
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
                                              markRotation: spinAngle,
                                              monochrome: IconStyle.monochrome)
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

    private func populate(_ menu: NSMenu, error: String?) {
        if let v = pendingUpdateVersion {
            let up = NSMenuItem(title: "⬆︎ Update to \(v)…",
                                action: #selector(installUpdate), keyEquivalent: "")
            up.target = self
            menu.addItem(up)
            menu.addItem(.separator())
        }
        if let error {
            menu.addItem(disabledItem(error, indented: !sessions.isEmpty))
        } else if sessions.isEmpty {
            menu.addItem(disabledItem("No Claude sessions"))
        }
        // Advise when a session runs a Claude Code too old to report the
        // waiting state — without it, that session can never turn red.
        if sessions.contains(where: { !SupportedVersion.isSupported($0.version) }) {
            menu.addItem(disabledItem("⚠ Update Claude Code to ≥ \(SupportedVersion.minimum)",
                                      indented: !sessions.isEmpty))
            menu.addItem(disabledItem("    older sessions may not show “waiting”",
                                      indented: !sessions.isEmpty))
        }
        for (index, session) in sessions.enumerated() {
            let mi = NSMenuItem(title: session.displayName,
                                action: #selector(jumpItem(_:)), keyEquivalent: "")
            mi.attributedTitle = Self.rowTitle(session.menuRow())
            mi.target = self
            mi.tag = index
            // Image column, not the state column: highlighted state-column
            // images get template-tinted white, which would erase the colors.
            mi.image = StatusIcon.image(for: session.light, monochrome: IconStyle.monochrome)
            mi.toolTip = "\(session.cwd)\n\(session.derivedName)"
            menu.addItem(mi)

            // ⌥ turns the row into Close, keeping its two-line height so the
            // menu does not jump while the key is held.
            let close = NSMenuItem(title: "Close “\(session.displayName)”…",
                                   action: #selector(closeItem(_:)), keyEquivalent: "")
            close.attributedTitle = Self.rowTitle(MenuRow(
                title: close.title,
                subtitle: CloseTarget.for(session).description(for: session), age: ""))
            close.target = self
            close.tag = index
            close.image = mi.image
            close.isAlternate = true
            close.keyEquivalentModifierMask = .option
            menu.addItem(close)
        }
        menu.addItem(.separator())

        let save = NSMenuItem(title: "Save Sessions", action: #selector(saveSessions), keyEquivalent: "")
        save.target = self
        save.image = Self.spacerImage
        menu.addItem(save)

        let restore = NSMenuItem(title: "Restore", action: nil, keyEquivalent: "")
        restore.image = Self.spacerImage
        let sub = NSMenu()
        let auto = NSMenuItem(title: "Auto Saved", action: nil, keyEquivalent: "")
        let autoSub = NSMenu()
        let autoToggle = NSMenuItem(title: "Auto Save", action: #selector(toggleAutoSave),
                                    keyEquivalent: "")
        autoToggle.target = self
        autoToggle.state = isAutoSaveOn() ? .on : .off
        autoSub.addItem(autoToggle)
        autoSub.addItem(.separator())
        addSnapshotEntries(autoSnapshotMenuEntries(), to: autoSub,
                           restore: #selector(restoreAutoItem(_:)),
                           delete: #selector(deleteAutoSnapshotItem(_:)))
        auto.submenu = autoSub
        sub.addItem(auto)
        sub.addItem(.separator())
        addSnapshotEntries(snapshotMenuEntries(), to: sub,
                           restore: #selector(restoreItem(_:)),
                           delete: #selector(deleteSnapshotItem(_:)))
        restore.submenu = sub
        menu.addItem(restore)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Show Light Bar", action: #selector(toggleBar), keyEquivalent: "")
        toggle.target = self
        toggle.image = isBarShown() ? Self.checkOnImage : Self.spacerImage
        menu.addItem(toggle)

        let sounds = NSMenuItem(title: "Notification Sounds", action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self
        sounds.image = Notifier.soundsEnabled ? Self.checkOnImage : Self.spacerImage
        menu.addItem(sounds)

        let mono = NSMenuItem(title: "Monochrome Icons", action: #selector(toggleMonochrome),
                              keyEquivalent: "")
        mono.target = self
        mono.image = IconStyle.monochrome ? Self.checkOnImage : Self.spacerImage
        menu.addItem(mono)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        if Bundle.main.bundleIdentifier != nil {
            login.target = self
        } // else: left targetless -> disabled under `swift run` (no bundle)
        login.image = SMAppService.mainApp.status == .enabled
            ? Self.checkOnImage : Self.spacerImage
        menu.addItem(login)

        let check = NSMenuItem(title: "Check for Updates…",
                               action: #selector(checkForUpdates), keyEquivalent: "")
        if Bundle.main.bundleIdentifier != nil {
            check.target = self
        } // else: left targetless -> disabled under `swift run` (no bundle)
        check.image = Self.spacerImage
        menu.addItem(check)

        let about = NSMenuItem(title: "About",
                               action: #selector(showAbout), keyEquivalent: "")
        if Bundle.main.bundleIdentifier != nil {
            about.target = self
        } // else: no bundle, no version to show
        about.image = Self.spacerImage
        menu.addItem(about)

        // Custom action, not NSApplication.terminate(_:) — macOS 26 infers a
        // system icon for the standard quit selector, which forces an image
        // column onto the whole section and misaligns it. No key equivalent
        // either: the shortcut column pads the menu's right edge.
        let quit = NSMenuItem(title: "Quit",
                              action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        quit.image = Self.spacerImage
        menu.addItem(quit)
    }

    /// Bold system checkmark matching the status dots' visual weight, on the
    /// dots' 18 pt canvas so both sections' image columns align. Template →
    /// tints with the item (black/white, follows dark mode and highlight).
    private static let checkOnImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        guard let symbol = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "on")?
            .withSymbolConfiguration(config) else { return nil }
        let side: CGFloat = 18 // = StatusIcon.image default diameter 14 + margin 2×2
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let s = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2,
                                   width: s.width, height: s.height))
            return true
        }
        img.isTemplate = true
        return img
    }()

    /// Transparent placeholder: the image column indents per item, so
    /// imageless items need this to share a text edge with icon-bearing ones.
    private static let spacerImage = NSImage(size: NSSize(width: 18, height: 18),
                                             flipped: false) { _ in true }

    /// Points from the title's start to the right-aligned age column.
    private static let ageColumn: CGFloat = 340

    /// Medium-weight title with the age right-aligned on a tab stop, over a smaller
    /// secondary-colored subtitle. Dynamic colors follow highlight and dark mode.
    private static func rowTitle(_ row: MenuRow) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: ageColumn)]
        para.lineBreakMode = .byTruncatingTail
        let base = NSFont.menuFont(ofSize: 0)
        let small = NSFont.menuFont(ofSize: base.pointSize - 2)
        let out = NSMutableAttributedString(string: row.title, attributes: [
            .font: NSFont.systemFont(ofSize: base.pointSize, weight: .medium), .paragraphStyle: para])
        out.append(NSAttributedString(string: "\t" + row.age, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: small.pointSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
        out.append(NSAttributedString(string: "\n" + row.subtitle, attributes: [
            .font: small, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
        return out
    }

    /// Snapshot rows, each with a ⌥ delete alternate, then the footer.
    private func addSnapshotEntries(_ entries: [SnapshotMenuEntry], to sub: NSMenu,
                                    restore: Selector, delete: Selector) {
        var footerStarted = false
        for entry in entries {
            let isFooter = entry.title == SnapshotMenu.restoreAllTitle
                || entry.title == SnapshotMenu.deleteHint
            if isFooter, !footerStarted { sub.addItem(.separator()); footerStarted = true }
            let mi = NSMenuItem(title: entry.title,
                                action: entry.enabled ? restore : nil,
                                keyEquivalent: "")
            mi.target = entry.enabled ? self : nil
            mi.isEnabled = entry.enabled
            mi.representedObject = entry.restoreName // nil → Restore All
            sub.addItem(mi)
            if let name = entry.deleteName {
                // Shown in place of the row above while ⌥ is held.
                let del = NSMenuItem(title: "Delete “\(name)”…", action: delete, keyEquivalent: "")
                del.target = self
                del.representedObject = name
                del.isAlternate = true
                del.keyEquivalentModifierMask = .option
                sub.addItem(del)
            }
        }
    }

    private func disabledItem(_ title: String, indented: Bool = false) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        if indented { mi.image = Self.spacerImage }
        return mi
    }

    @objc private func jumpItem(_ sender: NSMenuItem) {
        guard sessions.indices.contains(sender.tag) else { return }
        onJump?(sessions[sender.tag])
    }

    @objc private func closeItem(_ sender: NSMenuItem) {
        guard sessions.indices.contains(sender.tag) else { return }
        onCloseSession?(sessions[sender.tag])
    }

    @objc private func toggleBar() { onToggleBar?() }

    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func installUpdate() { onInstallUpdate?() }

    @objc private func checkForUpdates() { onCheckForUpdates?() }

    @objc private func saveSessions() { onSaveSessions?() }

    @objc private func restoreItem(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String {
            onRestore?([name])
        } else {
            onRestore?(nil)
        }
    }

    @objc private func deleteSnapshotItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        onDeleteSnapshot?(name)
    }

    @objc private func restoreAutoItem(_ sender: NSMenuItem) {
        onRestoreAuto?((sender.representedObject as? String).map { [$0] })
    }

    @objc private func deleteAutoSnapshotItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        onDeleteAutoSnapshot?(name)
    }

    @objc private func toggleAutoSave() { onToggleAutoSave?() }

    @objc private func showAbout() {
        // LSUIElement apps have no Dock presence; activate or the panel
        // opens behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func toggleSounds() { Notifier.soundsEnabled.toggle() }

    @objc private func toggleMonochrome() {
        IconStyle.monochrome.toggle()
        refreshButtonImage() // tray icon restyles at once; menu rebuilds on open
    }

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

extension StatusItemController: NSMenuDelegate {
    // Rebuild on every open so toggle checkmarks reflect the live state
    // immediately rather than lagging until the next poll.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        onMenuWillOpen?()
        populate(menu, error: lastError)
    }
}
