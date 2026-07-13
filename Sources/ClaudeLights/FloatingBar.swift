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
    private static let pinnedKey = "barPinnedTopRight"
    private static let snapThreshold: CGFloat = 40

    private let panel: NSPanel
    private let store: SessionStore
    private var manuallyHidden = UserDefaults.standard.bool(forKey: FloatingBar.hiddenKey)
    private var pinned = UserDefaults.standard.bool(forKey: FloatingBar.pinnedKey)
    private var isProgrammaticMove = false
    private var snapDebounce: DispatchWorkItem?

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
    /// While pinned, width changes keep the right/top edges anchored.
    func refresh() {
        if let host = panel.contentView as? NSHostingView<BarView> {
            let size = host.fittingSize
            if size.width > 0, size != panel.frame.size {
                panel.setContentSize(size)
            }
        }
        if let logPath = ProcessInfo.processInfo.environment["CLAUDE_LIGHTS_DEBUG_LOG"] {
            let fitting = (panel.contentView as? NSHostingView<BarView>)?.fittingSize ?? .zero
            let line = "\(Date()) frame=\(panel.frame) fitting=\(fitting) pinned=\(pinned) sessions=\(store.sessions.count)\n"
            if let data = line.data(using: .utf8), let h = FileHandle(forWritingAtPath: logPath) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
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

    /// NSHostingView auto-resizes the panel (anchored bottom-left) whenever
    /// the SwiftUI content changes size — our poll-time size diffing never
    /// sees it. Re-anchor the top-right corner on every actual resize.
    func windowDidResize(_ notification: Notification) {
        if pinned { applyPin(animate: false) }
    }

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove else { return }
        // Wait until the drag settles (mouse released), then decide snapping.
        snapDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settleAfterDrag() }
        snapDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func settleAfterDrag() {
        if NSEvent.pressedMouseButtons & 1 != 0 {
            // Still dragging: check again shortly.
            let work = DispatchWorkItem { [weak self] in self?.settleAfterDrag() }
            snapDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
            return
        }
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let shouldPin = SnapMath.shouldPin(barFrame: panel.frame, visible: visible,
                                           threshold: FloatingBar.snapThreshold)
        pinned = shouldPin
        UserDefaults.standard.set(pinned, forKey: FloatingBar.pinnedKey)
        if pinned {
            applyPin(animate: true)
        } else {
            UserDefaults.standard.set([panel.frame.origin.x, panel.frame.origin.y],
                                      forKey: FloatingBar.originKey)
        }
    }

    private func applyPin(animate: Bool) {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let origin = SnapMath.pinnedOrigin(barSize: panel.frame.size, visible: visible)
        guard origin != panel.frame.origin else { return }
        isProgrammaticMove = true
        if animate {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                panel.animator().setFrameOrigin(origin)
            }, completionHandler: { [weak self] in self?.isProgrammaticMove = false })
        } else {
            panel.setFrameOrigin(origin)
            isProgrammaticMove = false
        }
    }

    private func restoreOrigin() {
        if pinned {
            applyPin(animate: false)
        } else if let saved = UserDefaults.standard.array(forKey: FloatingBar.originKey) as? [Double],
           saved.count == 2 {
            panel.setFrameOrigin(NSPoint(x: saved[0], y: saved[1]))
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 240, y: frame.maxY - 44))
        }
    }
}
