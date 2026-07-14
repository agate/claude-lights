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

/// A single status dot for the floating bar. Colorblind-safe color plus a
/// glyph; the running state spins a gear (unless Reduce Motion is on).
struct DotView: View {
    let light: LightState
    private let d: CGFloat = 14
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if StatusIcon.isHollow(light) {
                Circle().strokeBorder(Color(StatusIcon.color(light)), lineWidth: 1.8)
            } else {
                Circle().fill(Color(StatusIcon.color(light)))
            }
            switch light {
            case .yellow:
                Image(systemName: "gearshape.fill")
                    .resizable().scaledToFit()
                    .frame(width: d * 0.66, height: d * 0.66)
                    .foregroundColor(.white)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                            spinning = true
                        }
                    }
            case .red, .green:
                Text(StatusIcon.glyph(light) ?? "")
                    .font(.system(size: d * 0.64, weight: .heavy))
                    .foregroundColor(.white)
            case .greenSeen, .gray:
                EmptyView()
            }
        }
        .frame(width: d, height: d)
    }
}

struct BarView: View {
    @ObservedObject var store: SessionStore
    var onJump: (Session) -> Void
    var onHover: (Session, Bool, NSRect) -> Void

    var body: some View {
        HStack(spacing: 7) {
            ForEach(store.sessions) { session in
                DotView(light: session.light)
                    .id(session.light) // restart the spin animation on state change
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

/// Accepts the first click even though the panel never becomes key
/// (non-activating): without this, physical clicks are swallowed by the
/// window-activation policy and never reach the SwiftUI gestures.
private final class FirstMouseHostingView: NSHostingView<BarView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FloatingBar: NSObject, NSWindowDelegate {
    private static let originKey = "barOrigin" // legacy absolute position
    private static let fractionKey = "barFraction"
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
        panel.contentView = FirstMouseHostingView(rootView: BarView(
            store: store,
            onJump: onJump,
            onHover: { [weak self] session, hovering, anchor in
                self?.handleHover(session, hovering: hovering, anchor: anchor)
            }))

        configureTooltipPanel()
        restoreOrigin()

        // Displays changing (e.g. a monitor unplugged) reposition immediately;
        // regular focus-following happens on every poll via refresh().
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.followFocusedScreen() }
    }

    /// The screen the user is working on — approximated by cursor location.
    private var focusedScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? panel.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Keeps the bar on the screen the user is focused on. Pinned bars stick
    /// to that screen's top-right; free bars keep their relative position.
    private func followFocusedScreen() {
        guard panel.isVisible, let screen = focusedScreen else { return }
        if pinned {
            applyPin(animate: false)
        } else if panel.screen?.frame != screen.frame {
            let origin = SnapMath.origin(fraction: savedFraction(),
                                         size: panel.frame.size,
                                         visible: screen.visibleFrame)
            isProgrammaticMove = true
            panel.setFrameOrigin(origin)
            isProgrammaticMove = false
        }
    }

    private func savedFraction() -> CGPoint {
        if let f = UserDefaults.standard.array(forKey: FloatingBar.fractionKey) as? [Double],
           f.count == 2 {
            return CGPoint(x: f[0], y: f[1])
        }
        return CGPoint(x: 0.9, y: 0.97)
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
            followFocusedScreen()
        } else {
            panel.removeChildWindow(tooltipPanel)
            tooltipPanel.orderOut(nil)
            panel.orderOut(nil)
        }
    }

    /// Debug hook: logs which view AppKit hit-testing resolves at the first
    /// dot's position — reveals whether an NSView is swallowing clicks.
    func debugLogHitTest() {
        guard let logPath = ProcessInfo.processInfo.environment["CLAUDE_LIGHTS_DEBUG_LOG"],
              let content = panel.contentView else { return }
        let point = NSPoint(x: 18, y: content.bounds.midY)
        let hit = content.hitTest(point)
        let line = "hitTest at \(point) -> \(hit.map { String(describing: type(of: $0)) } ?? "nil")\n"
        if let data = line.data(using: .utf8), let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        }
    }

    /// Debug hook: synthesizes a click on the first dot, delivered straight
    /// to the panel — tests the gesture pipeline while bypassing the system
    /// event routing (first-mouse/activation policies).
    func debugSyntheticClick() {
        guard let content = panel.contentView else { return }
        let local = NSPoint(x: 18, y: content.bounds.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: local, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) {
                panel.sendEvent(event)
            }
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

    /// Whether the user wants the bar shown (independent of auto-hide when
    /// there are no sessions).
    var isShown: Bool { !manuallyHidden }

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
            let fraction = SnapMath.fraction(origin: panel.frame.origin,
                                             size: panel.frame.size, visible: visible)
            UserDefaults.standard.set([fraction.x, fraction.y], forKey: FloatingBar.fractionKey)
        }
    }

    private func applyPin(animate: Bool) {
        guard let visible = focusedScreen?.visibleFrame else { return }
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
            return
        }
        // Migrate a legacy absolute origin to the screen-relative fraction.
        if UserDefaults.standard.array(forKey: FloatingBar.fractionKey) == nil,
           let legacy = UserDefaults.standard.array(forKey: FloatingBar.originKey) as? [Double],
           legacy.count == 2, let visible = NSScreen.main?.visibleFrame {
            let fraction = SnapMath.fraction(origin: CGPoint(x: legacy[0], y: legacy[1]),
                                             size: panel.frame.size, visible: visible)
            UserDefaults.standard.set([fraction.x, fraction.y], forKey: FloatingBar.fractionKey)
            UserDefaults.standard.removeObject(forKey: FloatingBar.originKey)
        }
        if let visible = (focusedScreen ?? NSScreen.main)?.visibleFrame {
            isProgrammaticMove = true
            panel.setFrameOrigin(SnapMath.origin(fraction: savedFraction(),
                                                 size: panel.frame.size, visible: visible))
            isProgrammaticMove = false
        }
    }
}
