import AppKit
import ClaudeLightsCore

/// One session's details (directory, summary, status, location, version)
/// and a Close item. Shared by the bar's right-click menu and the tray's ⌥
/// session submenus. Filled lazily on open, so the 2 MB transcript read for
/// the summary only happens for the submenu actually shown. Menu items hold
/// their target weakly: the owner must keep this object alive.
final class SessionDetailsMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let session: Session
    private let onClose: (Session) -> Void

    /// Points from the menu row's text start to the value column.
    private static let labelColumn: CGFloat = 76

    init(session: Session, onClose: @escaping (Session) -> Void) {
        self.session = session
        self.onClose = onClose
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.items.isEmpty else { return }
        populate()
    }

    private func populate() {
        let title = NSMenuItem(title: session.displayName, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let home = NSHomeDirectory()
        let path = session.cwd.hasPrefix(home) ? "~" + session.cwd.dropFirst(home.count) : session.cwd
        row("Directory", String(path), action: #selector(copyPath))
        menu.items.last?.toolTip = "Click to copy the full path"

        let url = TranscriptReader.transcriptURL(cwd: session.cwd, sessionId: session.id)
        if let summary = TranscriptReader.sessionSummary(
            fromJSONLines: TranscriptReader.tailLines(of: url, maxBytes: 2 * 1024 * 1024)) {
            let source: String
            switch summary.kind {
            case .recap:
                let age = AgeFormatter.string(from: summary.date)
                source = age.isEmpty ? "Claude's recap" : "Claude's recap, \(age)"
            case .lastPrompt:
                source = "Your last prompt (no recap yet)"
            }
            row("Summary", source, valueColor: .secondaryLabelColor)
            // One text wrapped over several rows, aligned under the values.
            TranscriptReader.wrap(summary.text).forEach { row("", $0) }
        }
        row("Status", [session.statusText, session.waitingFor].compactMap { $0 }.joined(separator: " · "))
        row("Runs in", session.locationLine)
        if let version = session.version { row("Version", "Claude Code \(version)") }

        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close “\(session.displayName)”…",
                               action: #selector(closeSession), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
    }

    /// "Label<tab>value": labels small and secondary in a fixed column,
    /// values in the label color. Explicit colors keep the value readable
    /// although the item is disabled.
    private func row(_ label: String, _ value: String, valueColor: NSColor = .labelColor,
                     action: Selector? = nil) {
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: Self.labelColumn)]
        let item = NSMenuItem(title: "\(label) \(value)", action: action, keyEquivalent: "")
        let title = NSMutableAttributedString(string: label + "\t", attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para])
        title.append(NSAttributedString(string: value, attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: valueColor, .paragraphStyle: para]))
        item.attributedTitle = title
        if action != nil {
            item.target = self
        } else {
            item.isEnabled = false
        }
        menu.addItem(item)
    }

    /// Fills now, for a menu popped up directly (no submenu open event).
    func populatedMenu() -> NSMenu {
        if menu.items.isEmpty { populate() }
        return menu
    }

    @objc private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.cwd, forType: .string)
    }

    @objc private func closeSession() { onClose(session) }
}
