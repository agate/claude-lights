import XCTest
@testable import ClaudeLightsCore

final class ProcessTableTests: XCTestCase {
    // pid ppid pgid tpgid args
    let fixture = """
      100     1   100   100 -zsh
      200     1   200   300 -zsh
      300   200   300   300 tail -f log.txt
      301   200   300   300 grep error
      400     1   400   500 -zsh
      500   400   500   500 npm run dev
      501   500   500   500 node server.js
      600     1   600     0 -zsh
    """

    func testHasAncestorWalksParentChain() {
        let t = ProcessTable.parse("""
          900     1   900   900 /Users/dev/.local/bin/herdr server
          910   900   910   920 -zsh
          920   910   920   920 claude
          930     1   930   930 -zsh
          940   930   940   940 claude
        """)
        let herdr = { (args: String) in args.hasSuffix("herdr server") }
        XCTAssertTrue(t.hasAncestor(of: 920, where: herdr))
        XCTAssertFalse(t.hasAncestor(of: 940, where: herdr))
        XCTAssertFalse(t.hasAncestor(of: 999, where: herdr)) // unknown pid
    }

    func testIdleShellHasNoCommand() {
        let t = ProcessTable.parse(fixture)
        XCTAssertNil(t.foregroundCommand(shellPid: 100)) // tpgid == own pgid
        XCTAssertNil(t.foregroundCommand(shellPid: 600)) // no controlling terminal group
        XCTAssertNil(t.foregroundCommand(shellPid: 999)) // unknown pid
    }

    func testPipelineJoinedInPidOrder() {
        let t = ProcessTable.parse(fixture)
        XCTAssertEqual(t.foregroundCommand(shellPid: 200), "tail -f log.txt | grep error")
    }

    func testOnlyDirectChildrenCount() {
        let t = ProcessTable.parse(fixture)
        XCTAssertEqual(t.foregroundCommand(shellPid: 400), "npm run dev")
    }

    func testSkipsMalformedLines() {
        let t = ProcessTable.parse("garbage\n  7 1 7 7 vim\n")
        XCTAssertNil(t.foregroundCommand(shellPid: 7))
    }

    func testClaudeCommandCountCountsShellSnapshotChildrenOnly() {
        let t = ProcessTable.parse("""
          800     1   800   800 claude
          810   800   810   810 /bin/zsh -c source /Users/dev/.claude/shell-snapshots/snapshot-zsh-1-a.sh 2>/dev/null || true && eval 'npm test'
          811   800   811   811 /bin/zsh -c source /Users/dev/.claude/shell-snapshots/snapshot-zsh-1-a.sh 2>/dev/null || true && eval 'sleep 99'
          812   800   812   812 caffeinate -i -t 300
          813   800   813   813 node /Users/dev/mcp/server.js
          820   810   810   810 npm test
        """)
        XCTAssertEqual(t.claudeCommandCount(claudePid: 800), 2)
        XCTAssertEqual(t.claudeCommandCount(claudePid: 999), 0)
    }

    func testClaudeCommandGroupsAreTheCommandsOwnGroups() {
        let t = ProcessTable.parse("""
          800     1   800   800 claude
          810   800   810   810 /bin/zsh -c source /Users/dev/.claude/shell-snapshots/snapshot-zsh-1-a.sh && eval 'npm run dev'
          811   800   811   811 /bin/zsh -c source /Users/dev/.claude/shell-snapshots/snapshot-zsh-1-a.sh && eval 'sleep 99'
          813   800   800   800 node /Users/dev/mcp/server.js
        """)
        XCTAssertEqual(t.claudeCommandGroups(claudePid: 800), [810, 811])
        XCTAssertEqual(t.claudeCommandGroups(claudePid: 999), [])
    }
}
