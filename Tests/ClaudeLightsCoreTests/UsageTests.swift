import XCTest
@testable import ClaudeLightsCore

final class UsageTests: XCTestCase {
    /// Shaped like Claude Code 2.1.306's get_usage answer (synthetic values).
    static let response = """
    {"type":"system","subtype":"hook_started"}
    {"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{\
    "subscription_type":"enterprise","rate_limits_available":true,"rate_limits":{\
    "five_hour":{"utilization":9,"resets_at":"2026-10-21T19:40:00.009893+00:00"},\
    "seven_day":null,\
    "extra_usage":{"is_enabled":true,"monthly_limit":20000,"used_credits":810,"utilization":4.05,\
    "currency":"USD","decimal_places":2},\
    "limits":[\
    {"kind":"session","group":"session","percent":9,"resets_at":"2026-10-21T19:40:00.009893+00:00","scope":null},\
    {"kind":"weekly_scoped","group":"weekly","percent":6,"resets_at":"2026-10-22T10:00:00.010057+00:00",\
    "scope":{"model":{"display_name":"Fable","id":null},"surface":null}}]}}}}
    """

    static let fetchedAt = Date(timeIntervalSince1970: 1_792_600_000)

    func report() -> UsageReport {
        UsageReport.parse(streamJSON: Self.response, fetchedAt: Self.fetchedAt)!
    }

    // MARK: parse

    func testParsesSession() {
        let r = report()
        XCTAssertEqual(r.session?.percentUsed, 9)
        XCTAssertEqual(r.session?.resetsAt, ISO8601DateFormatter().date(from: "2026-10-21T19:40:00Z"))
    }

    func testParsesWeeklyScoped() {
        let r = report()
        XCTAssertEqual(r.weekly.count, 1)
        XCTAssertEqual(r.weekly.first?.name, "Fable")
        XCTAssertEqual(r.weekly.first?.limit.percentUsed, 6)
    }

    func testParsesCredit() {
        let c = report().credit
        XCTAssertEqual(c?.usedMinor, 810)
        XCTAssertEqual(c?.limitMinor, 20000)
        XCTAssertEqual(c?.decimals, 2)
        XCTAssertEqual(c?.currency, "USD")
    }

    func testFetchedAtKept() {
        XCTAssertEqual(report().fetchedAt, Self.fetchedAt)
    }

    func testSessionFallsBackToFiveHour() {
        let json = """
        {"type":"control_response","response":{"subtype":"success","response":{"rate_limits":{\
        "five_hour":{"utilization":42.4,"resets_at":"2026-10-21T19:40:00+00:00"}}}}}
        """
        let r = UsageReport.parse(streamJSON: json, fetchedAt: Self.fetchedAt)
        XCTAssertEqual(r?.session?.percentUsed, 42.4)
        XCTAssertEqual(r?.weekly, [])
        XCTAssertNil(r?.credit)
    }

    func testUnscopedWeeklyIsAllModels() {
        let json = """
        {"type":"control_response","response":{"subtype":"success","response":{"rate_limits":{\
        "limits":[{"group":"weekly","percent":30,"resets_at":"2026-10-22T10:00:00+00:00","scope":null}]}}}}
        """
        let r = UsageReport.parse(streamJSON: json, fetchedAt: Self.fetchedAt)
        XCTAssertEqual(r?.weekly.first?.name, "All models")
    }

    func testDisabledCreditIsDropped() {
        let json = """
        {"type":"control_response","response":{"subtype":"success","response":{"rate_limits":{\
        "five_hour":{"utilization":1},\
        "extra_usage":{"is_enabled":false,"monthly_limit":20000,"used_credits":0}}}}}
        """
        XCTAssertNil(UsageReport.parse(streamJSON: json, fetchedAt: Self.fetchedAt)?.credit)
    }

    func testErrorResponseIsNil() {
        let json = """
        {"type":"control_response","response":{"subtype":"error","error":"not logged in"}}
        """
        XCTAssertNil(UsageReport.parse(streamJSON: json, fetchedAt: Self.fetchedAt))
    }

    func testNoRateLimitsIsNil() {
        let json = """
        {"type":"control_response","response":{"subtype":"success","response":{"rate_limits_available":false}}}
        """
        XCTAssertNil(UsageReport.parse(streamJSON: json, fetchedAt: Self.fetchedAt))
    }

    /// What Claude Code 2.1.306 answers with no login (empty CLAUDE_CONFIG_DIR).
    static let signedOut = """
    {"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{\
    "session":{"total_cost_usd":0},"subscription_type":null,"rate_limits_available":false,\
    "rate_limits":null,"behaviors":null}}}
    """

    func testSignedOutIsNilAndRecognized() {
        XCTAssertNil(UsageReport.parse(streamJSON: Self.signedOut, fetchedAt: Self.fetchedAt))
        XCTAssertTrue(UsageReport.isSignedOut(streamJSON: Self.signedOut))
    }

    func testSignedInAndFailuresAreNotSignedOut() {
        XCTAssertFalse(UsageReport.isSignedOut(streamJSON: Self.response))
        XCTAssertFalse(UsageReport.isSignedOut(streamJSON: "")) // timeout / crash: keep last report
        XCTAssertFalse(UsageReport.isSignedOut(streamJSON: """
        {"type":"control_response","response":{"subtype":"error","error":"network"}}
        """))
    }

    func testGarbageIsNil() {
        XCTAssertNil(UsageReport.parse(streamJSON: "not json\n{}", fetchedAt: Self.fetchedAt))
    }

    // MARK: rows

    func rows(now: Date) -> [UsageRow] {
        UsageMenu.rows(report(), now: now, timeZone: TimeZone(identifier: "UTC")!,
                       locale: Locale(identifier: "en_US"))
    }

    func testRowsTitlesAndDetails() {
        let now = ISO8601DateFormatter().date(from: "2026-10-21T10:00:00Z")!
        let r = rows(now: now)
        XCTAssertEqual(r.map(\.title), ["Session (5h)", "Fable (weekly)", "Credit"])
        // ICU puts a narrow no-break space before AM/PM.
        let detail = { (i: Int) in r[i].detail.replacingOccurrences(of: "\u{202F}", with: " ") }
        XCTAssertEqual(detail(0), "91% left · resets 7:40 PM")
        XCTAssertEqual(detail(1), "94% left · resets Thu 10:00 AM")
        XCTAssertEqual(r[2].detail, "$191.90 left of $200")
    }

    func testRowFractions() {
        let r = rows(now: Self.fetchedAt)
        XCTAssertEqual(r[0].fractionUsed, 0.09, accuracy: 0.0001)
        XCTAssertEqual(r[1].fractionUsed, 0.06, accuracy: 0.0001)
        XCTAssertEqual(r[2].fractionUsed, 0.0405, accuracy: 0.0001)
    }

    func testPercentClampsAndRounds() {
        let over = UsageLimit(percentUsed: 104, resetsAt: nil)
        XCTAssertEqual(UsageMenu.leftText(over), "0% left")
        XCTAssertEqual(UsageMenu.leftText(UsageLimit(percentUsed: 4.6, resetsAt: nil)), "95% left")
        XCTAssertEqual(over.fractionUsed, 1)
    }

    func testMoney() {
        XCTAssertEqual(UsageMenu.money(19190, decimals: 2, currency: "USD"), "$191.90")
        XCTAssertEqual(UsageMenu.money(20000, decimals: 2, currency: "USD"), "$200")
        XCTAssertEqual(UsageMenu.money(1250, decimals: 2, currency: "EUR"), "12.50 EUR")
        XCTAssertEqual(UsageMenu.money(-5, decimals: 2, currency: "USD"), "$0")
    }

    func testUpdatedText() {
        let t = Self.fetchedAt
        XCTAssertEqual(UsageMenu.updatedText(fetchedAt: t, now: t.addingTimeInterval(20)), "Updated just now")
        XCTAssertEqual(UsageMenu.updatedText(fetchedAt: t, now: t.addingTimeInterval(130)), "Updated 2 min ago")
        XCTAssertEqual(UsageMenu.updatedText(fetchedAt: t, now: t.addingTimeInterval(7300)), "Updated 2 h ago")
    }

    func testStale() {
        let r = report()
        XCTAssertFalse(r.isStale(now: Self.fetchedAt.addingTimeInterval(44 * 60)))
        XCTAssertTrue(r.isStale(now: Self.fetchedAt.addingTimeInterval(46 * 60)))
    }

    // MARK: probe filter

    func testProbeRecordIsRecognizedByCwd() {
        let dir = "/Users/x/Library/Caches/ClaudeLights/usage-probe"
        XCTAssertTrue(UsageProbe.isProbe(AgentRecord(cwd: dir), probeDir: dir))
        XCTAssertTrue(UsageProbe.isProbe(AgentRecord(cwd: dir + "/"), probeDir: dir))
        XCTAssertFalse(UsageProbe.isProbe(AgentRecord(cwd: "/Users/x/code"), probeDir: dir))
        XCTAssertFalse(UsageProbe.isProbe(AgentRecord(cwd: nil), probeDir: dir))
    }
}
