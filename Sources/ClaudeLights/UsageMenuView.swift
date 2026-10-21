import AppKit
import ClaudeLightsCore

/// The menu's read-only Usage section: a header ("Usage", then "Updated …
/// ago" and a refresh button on the right), one row per limit (title,
/// right-aligned "N% left · resets …", thin neutral meter of the used share).
/// A custom view so the meters and the button fit; colors are dynamic, so it
/// follows light/dark mode. `show` updates it in place while the menu is open.
final class UsageMenuView: NSView {
    /// Text edge of the image-column menu items below.
    static let leading: CGFloat = 40.5
    private static let trailing: CGFloat = 14
    private static let headerHeight: CGFloat = 24
    private static let rowHeight: CGFloat = 27
    private static let buttonSide: CGFloat = 18
    /// Least space between a row's title and its right-aligned detail.
    private static let titleGap: CGFloat = 16

    private var rows: [UsageRow] = []
    private var updated = ""
    private var refreshing = false
    private let button = NSButton()
    private let onRefresh: () -> Void

    init(width: CGFloat, onRefresh: @escaping () -> Void) {
        self.onRefresh = onRefresh
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.headerHeight))
        autoresizingMask = [.width]
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "arrow.clockwise",
                               accessibilityDescription: "Refresh usage")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Refresh now"
        button.target = self
        button.action = #selector(refresh)
        button.autoresizingMask = [.minXMargin]
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func show(_ report: UsageReport) {
        rows = UsageMenu.rows(report, now: Date())
        updated = UsageMenu.updatedText(fetchedAt: report.fetchedAt, now: Date())
        refreshing = false
        layoutContent()
    }

    func refreshFailed() {
        refreshing = false
        layoutContent()
    }

    @objc private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        layoutContent()
        onRefresh()
    }

    private func layoutContent() {
        // Widen (never narrow) when a title and its detail would overlap,
        // e.g. "All models (weekly)" with a reset days away.
        let needed = rows.map {
            Self.leading + Self.title($0.title).size().width + Self.titleGap
                + Self.detail($0.detail).size().width + Self.trailing
        }.max() ?? 0
        setFrameSize(NSSize(width: max(frame.width, needed.rounded(.up)),
                            height: Self.headerHeight + CGFloat(rows.count) * Self.rowHeight + 4))
        button.frame = NSRect(x: frame.width - Self.trailing - Self.buttonSide + 3, y: 3,
                              width: Self.buttonSide, height: Self.buttonSide)
        button.isEnabled = !refreshing
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let base = NSFont.menuFont(ofSize: 0)
        let small = NSFont.menuFont(ofSize: base.pointSize - 2)
        let right = bounds.width - Self.trailing

        NSAttributedString(string: "Usage", attributes: [
            .font: NSFont.systemFont(ofSize: small.pointSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]).draw(at: NSPoint(x: Self.leading, y: 5))
        let status = NSAttributedString(string: refreshing ? "Updating…" : updated, attributes: [
            .font: small, .foregroundColor: NSColor.secondaryLabelColor,
        ])
        status.draw(at: NSPoint(x: right - Self.buttonSide - 2 - status.size().width, y: 5))

        var y = Self.headerHeight
        for row in rows {
            Self.title(row.title).draw(at: NSPoint(x: Self.leading, y: y))
            let detail = Self.detail(row.detail)
            let size = detail.size()
            detail.draw(at: NSPoint(x: right - size.width, y: y + (base.pointSize - small.pointSize) / 2 + 1))

            let track = NSRect(x: Self.leading, y: y + base.pointSize + 7,
                               width: right - Self.leading, height: 3)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
            if row.fractionUsed > 0 {
                var fill = track
                fill.size.width = max(track.height, track.width * CGFloat(row.fractionUsed))
                NSColor.secondaryLabelColor.setFill()
                NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
            }
            y += Self.rowHeight
        }
    }

    private static func title(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor,
        ])
    }

    private static func detail(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 2,
                                                    weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }
}
