import XCTest
@testable import ClaudeLightsCore

final class HerdrMapperTests: XCTestCase {
    // Trimmed real output of `herdr agent list` (herdr 0.9.5).
    let agentList = """
    {"id":"cli:agent:list","result":{"agents":[\
    {"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude",\
    "value":"113e1ce7-31bb-4a9a-a824-ba644d962729"},"agent_status":"idle","cwd":"/Users/dev",\
    "focused":true,"pane_id":"w5:p1","tab_id":"w5:t1","workspace_id":"w5"},\
    {"agent":"claude","agent_status":"working","focused":false,"pane_id":"w2:p3"}\
    ],"type":"agent_list"}}
    """

    func testParseAgents() {
        let agents = HerdrMapper.parseAgents(agentList)
        XCTAssertEqual(agents, [
            HerdrAgent(paneId: "w5:p1", sessionId: "113e1ce7-31bb-4a9a-a824-ba644d962729",
                       isFocused: true),
            HerdrAgent(paneId: "w2:p3", sessionId: nil, isFocused: false),
        ])
    }

    func testParseAgentsToleratesGarbage() {
        XCTAssertEqual(HerdrMapper.parseAgents(""), [])
        XCTAssertEqual(HerdrMapper.parseAgents("not json"), [])
        XCTAssertEqual(HerdrMapper.parseAgents(#"{"result":{"agents":[{"focused":true}]}}"#), [])
    }

    func testParseClientTtysKeepsOnlyDefaultSessionClients() {
        // Only the default server is queried for panes, so only its clients
        // may be focused; a named-session client shows other panes.
        let ps = """
        ttys029  herdr
        ttys030  /Users/dev/.local/bin/herdr --session default
        ttys031  herdr session attach default
        ttys034  herdr --session=default
        ttys035  herdr --session work
        ttys036  herdr --session=work
        ttys037  herdr session attach work
        ??       /Users/dev/.local/bin/herdr server
        ttys032  herdr agent list
        ttys033  /bin/zsh -c herdr
        ??       herdr
        """
        XCTAssertEqual(HerdrMapper.parseClientTtys(ps),
                       ["/dev/ttys029", "/dev/ttys030", "/dev/ttys031", "/dev/ttys034"])
    }

    func testIsServerCommand() {
        XCTAssertTrue(HerdrMapper.isServerCommand("/Users/dev/.local/bin/herdr server"))
        XCTAssertTrue(HerdrMapper.isServerCommand("herdr server"))
        XCTAssertFalse(HerdrMapper.isServerCommand("herdr"))
        XCTAssertFalse(HerdrMapper.isServerCommand("tmux new -s server"))
    }

    func testBuilderMapsSessionToHerdrPaneBySessionId() {
        let record = AgentRecord(pid: 7, cwd: "/Users/dev/h", kind: "interactive",
                                 sessionId: "abc", status: "idle")
        let sessions = SessionBuilder.build(
            records: [record], pidTtys: [7: "/dev/ttys025"], panes: [],
            herdrAgents: [HerdrAgent(paneId: "w5:p1", sessionId: "abc", isFocused: true),
                          HerdrAgent(paneId: "w1:p1", sessionId: "other", isFocused: false)])
        XCTAssertEqual(sessions.first?.herdrPane, "w5:p1")
        XCTAssertNil(sessions.first?.tmuxSession)
    }

    func testHerdrFocusedIdsNeedsFrontmostHerdrClient() {
        let a = Session(id: "a", pid: 1, cwd: "/", projectName: "a", derivedName: "",
                        light: .green, statusText: "", statusUpdatedAt: nil,
                        tmuxSession: nil, tmuxWindow: nil, herdrPane: "w5:p1")
        let b = Session(id: "b", pid: 2, cwd: "/", projectName: "b", derivedName: "",
                        light: .green, statusText: "", statusUpdatedAt: nil,
                        tmuxSession: nil, tmuxWindow: nil, herdrPane: "w5:p2")
        XCTAssertEqual(SeenTracker.herdrFocusedIds(sessions: [a, b], focusedPaneId: "w5:p1"), ["a"])
        XCTAssertEqual(SeenTracker.herdrFocusedIds(sessions: [a, b], focusedPaneId: nil), [])
    }

    func testSummaryLineDoesNotSayNotInTmuxForHerdr() {
        let s = Session(id: "a", pid: 1, cwd: "/", projectName: "a", derivedName: "",
                        light: .yellow, statusText: "Working", statusUpdatedAt: nil,
                        tmuxSession: nil, tmuxWindow: nil, herdrPane: "w5:p1")
        XCTAssertFalse(s.summaryLine().contains("not in tmux"))
    }
}
