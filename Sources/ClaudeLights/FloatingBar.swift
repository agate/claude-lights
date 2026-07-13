import AppKit
import SwiftUI
import ClaudeLightsCore

/// Reports mouse enter/exit over a SwiftUI view using an `.activeAlways`
/// tracking area. System tooltips (`.help()`) never appear over this panel:
/// NSToolTipManager only shows them while the app is active, and this app is
/// by design never activated (accessory + non-activating panel).
private final class TrackingView: NSView {
    var onChange: ((Bool, NSRect) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    private var screenRect: NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    override func mouseEntered(with event: NSEvent) { onChange?(true, screenRect) }
    override func mouseExited(with event: NSEvent) { onChange?(false, screenRect) }
}

struct HoverReporter: NSViewRepresentable {
    var onChange: (Bool, NSRect) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackingView)?.onChange = onChange
    }
}

struct BarView: View {
    @ObservedObject var store: SessionStore
    var onJump: (Session) -> Void
    var onHover: (Session, Bool, NSRect) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(store.sessions) { session in
                Circle()
                    .fill(Color(StatusIcon.color(session.light)))
                    .frame(width: 12, height: 12)
                    .background(HoverReporter { hovering, anchor in
                        onHover(session, hovering, anchor)
                    })
                    .onTapGesture { onJump(session) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .fixedSize()
    }
}

final class FloatingBar: NSObject, NSWindowDelegate {
    private static let originKey = "barOrigin"
    private static let hiddenKey = "barHidden"

    private let panel: NSPanel
    private let store: SessionStore
    private var manuallyHidden = UserDefaults.standard.bool(forKey: FloatingBar.hiddenKey)

    private let tooltipPanel: NSPanel
    private let tooltipLabel = NSTextField(labelWithString: "")

    init(store: SessionStore, onJump: @escaping (Session) -> Void) {
        self.store = store
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 28),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        tooltipPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        super.init()
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: BarView(
            store: store,
            onJump: onJump,
            onHover: { [weak self] session, hovering, anchor in
                self?.handleHover(session, hovering: hovering, anchor: anchor)
            }))

        configureTooltipPanel()
        restoreOrigin()
    }

    private func configureTooltipPanel() {
        tooltipPanel.level = .statusBar
        tooltipPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        tooltipPanel.isOpaque = false
        tooltipPanel.backgroundColor = .clear
        tooltipPanel.hasShadow = true
        tooltipPanel.ignoresMouseEvents = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6
        effect.layer?.masksToBounds = true

        tooltipLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tooltipLabel.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(tooltipLabel)
        NSLayoutConstraint.activate([
            tooltipLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
            tooltipLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            tooltipLabel.topAnchor.constraint(equalTo: effect.topAnchor, constant: 4),
            tooltipLabel.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -4),
        ])
        tooltipPanel.contentView = effect
    }

    private func handleHover(_ session: Session, hovering: Bool, anchor: NSRect) {
        guard hovering else {
            panel.removeChildWindow(tooltipPanel)
            tooltipPanel.orderOut(nil)
            return
        }
        tooltipLabel.stringValue = session.summaryLine()
        tooltipLabel.sizeToFit()
        let size = NSSize(width: tooltipLabel.frame.width + 16,
                          height: tooltipLabel.frame.height + 8)
        tooltipPanel.setContentSize(size)

        var x = anchor.midX - size.width / 2
        let y = anchor.minY - size.height - 8
        if let screen = panel.screen ?? NSScreen.main {
            x = min(max(x, screen.visibleFrame.minX + 4),
                    screen.visibleFrame.maxX - size.width - 4)
        }
        tooltipPanel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.addChildWindow(tooltipPanel, ordered: .above)
        tooltipPanel.orderFrontRegardless()
    }

    /// Re-fit size and show/hide according to session count and user toggle.
    func refresh() {
        if let host = panel.contentView as? NSHostingView<BarView> {
            let size = host.fittingSize
            if size.width > 0, size != panel.frame.size {
                panel.setContentSize(size)
            }
        }
        let shouldShow = !store.sessions.isEmpty && !manuallyHidden
        if shouldShow {
            panel.orderFrontRegardless()
        } else {
            panel.removeChildWindow(tooltipPanel)
            tooltipPanel.orderOut(nil)
            panel.orderOut(nil)
        }
    }

    /// Demo/testing hook: renders the bar's own content to a PNG (with
    /// alpha). Self-rendering needs no screen-recording permission.
    func snapshot(to url: URL) {
        guard panel.isVisible, let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    func toggle() {
        manuallyHidden.toggle()
        UserDefaults.standard.set(manuallyHidden, forKey: FloatingBar.hiddenKey)
        refresh()
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set([panel.frame.origin.x, panel.frame.origin.y],
                                  forKey: FloatingBar.originKey)
    }

    private func restoreOrigin() {
        if let saved = UserDefaults.standard.array(forKey: FloatingBar.originKey) as? [Double],
           saved.count == 2 {
            panel.setFrameOrigin(NSPoint(x: saved[0], y: saved[1]))
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 240, y: frame.maxY - 44))
        }
    }
}
