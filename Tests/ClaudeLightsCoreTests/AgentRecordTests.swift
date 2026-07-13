import XCTest
@testable import ClaudeLightsCore

final class AgentRecordTests: XCTestCase {
    // Real registry file content captured from ~/.claude/sessions/783.json (2.1.207)
    let registryFixture = """
    {"pid":783,"sessionId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cwd":"/Users/dev","startedAt":1783747666861,"procStart":"Sat Jul 11 05:27:46 2026","version":"2.1.207","peerProtocol":1,"kind":"interactive","entrypoint":"cli","name":"dev-0b","nameSource":"derived","status":"busy","updatedAt":1783872850584,"statusUpdatedAt":1783872850584}
    """

    // Real `claude agents --json` output shape
    let listFixture = """
    [
      {"pid":9895,"id":"f1cea4f1","cwd":"/Users/dev/webapp","kind":"background","startedAt":1783717765103,"sessionId":"e93ce2d9","name":"bg task","status":"idle","state":"done"},
      {"pid":783,"cwd":"/Users/dev","kind":"interactive","startedAt":1783747666861,"sessionId":"de78fb42","name":"dev-0b","status":"busy"}
    ]
    """

    func testParseRegistryFile() {
        let r = AgentRecord.parseOne(registryFixture)
        XCTAssertEqual(r?.pid, 783)
        XCTAssertEqual(r?.kind, "interactive")
        XCTAssertEqual(r?.status, "busy")
        XCTAssertEqual(r?.statusUpdatedAt, 1783872850584)
        XCTAssertEqual(r?.cwd, "/Users/dev")
    }

    // Real waiting-state registry content captured live on 2.1.207 (Task 13)
    let waitingFixture = """
    {"pid":86398,"sessionId":"99999999-8888-7777-6666-555555555555","cwd":"/private/tmp","startedAt":1783874156815,"procStart":"Tue Jul 07 16:34:43 2026","version":"2.1.207","peerProtocol":1,"kind":"interactive","entrypoint":"cli","name":"tmp-29","nameSource":"derived","status":"waiting","updatedAt":1783874163920,"statusUpdatedAt":1783874163920,"waitingFor":"permission prompt"}
    """

    func testParseWaitingRegistryFile() {
        let r = AgentRecord.parseOne(waitingFixture)
        XCTAssertEqual(r?.status, "waiting")
        XCTAssertEqual(r?.waitingFor, "permission prompt")
        XCTAssertEqual(StateMapper.light(status: r?.status, state: r?.state), .red)
    }

    func testParseList() {
        let rs = AgentRecord.parseList(listFixture)
        XCTAssertEqual(rs.count, 2)
        XCTAssertEqual(rs[0].kind, "background")
        XCTAssertEqual(rs[1].sessionId, "de78fb42")
    }

    func testMalformedReturnsEmpty() {
        XCTAssertNil(AgentRecord.parseOne("not json"))
        XCTAssertEqual(AgentRecord.parseList("nope").count, 0)
    }

    func testRegistryLoadSkipsDeadPidsAndBadFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cl-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try registryFixture.write(to: dir.appendingPathComponent("783.json"), atomically: true, encoding: .utf8)
        try #"{"pid":999,"kind":"interactive","status":"busy","cwd":"/tmp"}"#
            .write(to: dir.appendingPathComponent("999.json"), atomically: true, encoding: .utf8)
        try "garbage".write(to: dir.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)

        let live = SessionRegistry.load(dir: dir, isAlive: { $0 == 783 })
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].pid, 783)
    }
}
