import Foundation

/// One rate-limit window: how much is used and when it resets.
public struct UsageLimit: Equatable, Sendable {
    /// 0–100, may be fractional and may exceed 100.
    public var percentUsed: Double
    public var resetsAt: Date?

    public init(percentUsed: Double, resetsAt: Date?) {
        self.percentUsed = percentUsed; self.resetsAt = resetsAt
    }

    /// 0...1, for meters.
    public var fractionUsed: Double { min(max(percentUsed / 100, 0), 1) }
}

/// A weekly limit scoped to one model (e.g. "Fable"), or to all models.
public struct WeeklyUsage: Equatable, Sendable {
    public var name: String
    public var limit: UsageLimit
}

/// Monthly extra-usage credit, in minor currency units (cents).
public struct CreditUsage: Equatable, Sendable {
    public var usedMinor: Int
    public var limitMinor: Int
    public var decimals: Int
    public var currency: String

    public var fractionUsed: Double {
        limitMinor > 0 ? min(max(Double(usedMinor) / Double(limitMinor), 0), 1) : 0
    }

    /// The answer carries no reset time for credit; Claude Code's own /usage
    /// takes the first of next month at local midnight, and so does this.
    public static func nextReset(after now: Date, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let month = calendar.dateComponents([.year, .month], from: now)
        let start = calendar.date(from: month) ?? now
        return calendar.date(byAdding: .month, value: 1, to: start) ?? now
    }
}

/// The account's limits as Claude Code's `get_usage` control request reports
/// them (the same data `/usage` shows). Undocumented shape: every field is
/// best-effort and a missing one just leaves its part nil/empty.
public struct UsageReport: Equatable, Sendable {
    /// The 5-hour window ("Current session" in /usage).
    public var session: UsageLimit?
    public var weekly: [WeeklyUsage]
    public var credit: CreditUsage?
    public var fetchedAt: Date

    /// Older than this, the tray meter is drawn faded: one 30-minute refresh
    /// missed, with slack so a slow fetch doesn't flicker it.
    public static let staleAfter: TimeInterval = 45 * 60

    public func isStale(now: Date) -> Bool { now.timeIntervalSince(fetchedAt) > Self.staleAfter }

    /// Parses the probe's stream-json stdout: finds the successful
    /// control_response and reads its `rate_limits`. Nil when there is none
    /// or it carries nothing displayable.
    public static func parse(streamJSON: String, fetchedAt: Date) -> UsageReport? {
        for line in streamJSON.split(whereSeparator: \.isNewline) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["type"] as? String == "control_response",
                  let outer = obj["response"] as? [String: Any],
                  outer["subtype"] as? String == "success",
                  let inner = outer["response"] as? [String: Any],
                  let limits = inner["rate_limits"] as? [String: Any] else { continue }
            let report = UsageReport(session: session(limits), weekly: weekly(limits),
                                     credit: credit(limits), fetchedAt: fetchedAt)
            if report.session == nil && report.weekly.isEmpty && report.credit == nil { return nil }
            return report
        }
        return nil
    }

    /// True when Claude Code answered but has no plan limits to report — not
    /// signed in, or signed in with an API key (`rate_limits_available:false`,
    /// `rate_limits:null`). Unlike a timeout or a network error, this is a
    /// definite answer: the last report must be dropped, not kept on screen.
    public static func isSignedOut(streamJSON: String) -> Bool {
        for line in streamJSON.split(whereSeparator: \.isNewline) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["type"] as? String == "control_response",
                  let outer = obj["response"] as? [String: Any],
                  outer["subtype"] as? String == "success",
                  let inner = outer["response"] as? [String: Any] else { continue }
            return inner["rate_limits_available"] as? Bool == false || inner["rate_limits"] is NSNull
        }
        return false
    }

    private static func scopedLimits(_ limits: [String: Any]) -> [[String: Any]] {
        limits["limits"] as? [[String: Any]] ?? []
    }

    private static func session(_ limits: [String: Any]) -> UsageLimit? {
        if let entry = scopedLimits(limits).first(where: { $0["group"] as? String == "session" }),
           let pct = number(entry["percent"]) {
            return UsageLimit(percentUsed: pct, resetsAt: date(entry["resets_at"]))
        }
        if let five = limits["five_hour"] as? [String: Any], let pct = number(five["utilization"]) {
            return UsageLimit(percentUsed: pct, resetsAt: date(five["resets_at"]))
        }
        return nil
    }

    private static func weekly(_ limits: [String: Any]) -> [WeeklyUsage] {
        scopedLimits(limits).compactMap { entry in
            guard entry["group"] as? String == "weekly", let pct = number(entry["percent"]) else { return nil }
            let scope = entry["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let name = (model?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return WeeklyUsage(name: name ?? "All models",
                               limit: UsageLimit(percentUsed: pct, resetsAt: date(entry["resets_at"])))
        }
    }

    private static func credit(_ limits: [String: Any]) -> CreditUsage? {
        guard let extra = limits["extra_usage"] as? [String: Any],
              extra["is_enabled"] as? Bool == true,
              let cap = number(extra["monthly_limit"]), cap > 0 else { return nil }
        return CreditUsage(usedMinor: Int(number(extra["used_credits"]) ?? 0),
                           limitMinor: Int(cap),
                           decimals: Int(number(extra["decimal_places"]) ?? 2),
                           currency: extra["currency"] as? String ?? "USD")
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, !(value is Bool) else { return nil }
        return n.doubleValue
    }

    /// "2026-10-21T19:40:00.009893+00:00" → whole seconds; the microseconds
    /// are noise for display and trip ISO8601DateFormatter.
    private static func date(_ value: Any?) -> Date? {
        guard var s = value as? String else { return nil }
        if let dot = s.firstIndex(of: ".") {
            let tail = s[dot...].drop(while: { $0 == "." || $0.isNumber })
            s = String(s[..<dot]) + tail
        }
        return ISO8601DateFormatter().date(from: s)
    }
}

/// One line of the menu's Usage section.
public struct UsageRow: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var fractionUsed: Double
}

public enum UsageMenu {
    public static func rows(_ report: UsageReport, now: Date,
                            timeZone: TimeZone = .current, locale: Locale = .current) -> [UsageRow] {
        var rows: [UsageRow] = []
        func resetSuffix(_ reset: Date, dateOnly: Bool = false) -> String {
            var text = " · resets " + resetText(reset, now: now, timeZone: timeZone, locale: locale,
                                                dateOnly: dateOnly)
            if let until = untilText(reset, now: now) { text += " · " + until }
            return text
        }
        func limitRow(_ title: String, _ limit: UsageLimit) -> UsageRow {
            var detail = leftText(limit)
            if let reset = limit.resetsAt { detail += resetSuffix(reset) }
            return UsageRow(title: title, detail: detail, fractionUsed: limit.fractionUsed)
        }
        if let session = report.session { rows.append(limitRow("Session (5h)", session)) }
        for week in report.weekly { rows.append(limitRow("\(week.name) (weekly)", week.limit)) }
        if let c = report.credit {
            let left = money(c.limitMinor - c.usedMinor, decimals: c.decimals, currency: c.currency)
            let cap = money(c.limitMinor, decimals: c.decimals, currency: c.currency)
            let reset = CreditUsage.nextReset(after: now, timeZone: timeZone)
            rows.append(UsageRow(title: "Credit", detail: "\(left) left of \(cap)" + resetSuffix(reset, dateOnly: true),
                                 fractionUsed: c.fractionUsed))
        }
        return rows
    }

    public static func leftText(_ limit: UsageLimit) -> String {
        "\(Int((100 - min(max(limit.percentUsed, 0), 100)).rounded()))% left"
    }

    /// Time only when the reset is today, else weekday + time; `dateOnly`
    /// (monthly credit) gives "Nov 1".
    static func resetText(_ date: Date, now: Date, timeZone: TimeZone, locale: Locale,
                          dateOnly: Bool = false) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        let template = dateOnly ? "MMMd" : calendar.isDate(date, inSameDayAs: now) ? "jmm" : "EEEjmm"
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    /// "in 20m", "in 1.5h", "in 6.5d", "in 1.5w": the largest unit that
    /// reaches 1, one decimal below 10 and whole from there. Nil once the
    /// reset is past (a stale report).
    public static func untilText(_ date: Date, now: Date) -> String? {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        func amount(_ value: Double) -> Double {
            value < 10 ? (value * 10).rounded() / 10 : value.rounded()
        }
        func number(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        }
        // Each unit is rounded before the next is tried, so 59.9 minutes
        // reads "1h", never "60m".
        let minutes = max(1, (seconds / 60).rounded())
        if minutes < 60 { return "in \(Int(minutes))m" }
        let hours = amount(seconds / 3600)
        if hours < 24 { return "in \(number(hours))h" }
        let days = amount(seconds / 86400)
        if days < 7 { return "in \(number(days))d" }
        return "in \(number(amount(seconds / (7 * 86400))))w"
    }

    /// "$191.90"; whole amounts drop the zero cents ("$200"). Negative → 0.
    public static func money(_ minor: Int, decimals: Int, currency: String) -> String {
        let scale = Int(pow(10, Double(max(decimals, 0))))
        let value = max(minor, 0)
        let whole = value / scale, frac = value % scale
        var number = String(whole)
        if frac != 0 { number += "." + String(format: "%0\(decimals)d", frac) }
        return currency == "USD" ? "$" + number : "\(number) \(currency)"
    }

    public static func updatedText(fetchedAt: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(fetchedAt) / 60)
        if minutes < 1 { return "Updated just now" }
        if minutes < 60 { return "Updated \(minutes)m ago" }
        return "Updated \(minutes / 60)h ago"
    }
}

/// The background `claude -p` that fetches usage registers itself in the
/// session registry like any session; it runs from its own directory so the
/// poller can drop it by cwd instead of showing a phantom dot.
public enum UsageProbe {
    public static var defaultDir: String {
        NSHomeDirectory() + "/Library/Caches/ClaudeLights/usage-probe"
    }

    public static func isProbe(_ record: AgentRecord, probeDir: String = defaultDir) -> Bool {
        guard let cwd = record.cwd else { return false }
        func norm(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }
        return norm(cwd) == norm(probeDir)
    }

    /// stdin for the probe: one get_usage control request.
    public static let request =
        #"{"type":"control_request","request_id":"usage","request":{"subtype":"get_usage","skip_behaviors":true}}"#
        + "\n"

    /// Hooks and MCP servers off (the user's SessionStart hooks would run
    /// every 5 minutes), nothing persisted; the CLI exits once stdin closes.
    public static let arguments = [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", "--no-session-persistence",
    ]
}
