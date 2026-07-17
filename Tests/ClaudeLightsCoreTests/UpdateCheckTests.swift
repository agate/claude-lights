import XCTest
@testable import ClaudeLightsCore

final class UpdateCheckTests: XCTestCase {
    // MARK: AppVersion

    func testParsePlain() {
        XCTAssertEqual(AppVersion("0.2.2")?.components, [0, 2, 2])
    }

    func testParseVPrefix() {
        XCTAssertEqual(AppVersion("v0.3.0")?.components, [0, 3, 0])
    }

    func testParseGarbage() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("abc"))
        XCTAssertNil(AppVersion("1.2.beta"))
        XCTAssertNil(AppVersion("v"))
    }

    func testCompareBasic() {
        XCTAssertTrue(AppVersion("0.2.2")! < AppVersion("0.3.0")!)
        XCTAssertTrue(AppVersion("0.9.9")! < AppVersion("1.0.0")!)
        XCTAssertFalse(AppVersion("0.3.0")! < AppVersion("0.2.2")!)
    }

    func testCompareDifferentLengths() {
        // "1.0" == "1" semantically; neither is less.
        XCTAssertFalse(AppVersion("1.0")! < AppVersion("1")!)
        XCTAssertFalse(AppVersion("1")! < AppVersion("1.0")!)
        XCTAssertEqual(AppVersion("1.0")!, AppVersion("1")!)
        XCTAssertTrue(AppVersion("1")! < AppVersion("1.0.1")!)
    }

    // MARK: ReleaseParser

    // Shape of api.github.com/repos/<owner>/<repo>/releases/latest
    let releaseFixture = """
    {"tag_name":"v0.3.0","html_url":"https://github.com/agate/claude-lights/releases/tag/v0.3.0",
     "draft":false,"prerelease":false,
     "assets":[
       {"name":"README.txt","browser_download_url":"https://example.com/README.txt"},
       {"name":"0.3.0.zip","browser_download_url":"https://github.com/agate/claude-lights/releases/download/v0.3.0/0.3.0.zip"},
       {"name":"other.zip","browser_download_url":"https://example.com/other.zip"}
     ]}
    """

    func testParseRelease() {
        let r = ReleaseParser.parse(releaseFixture)
        XCTAssertEqual(r?.tag, "v0.3.0")
        XCTAssertEqual(r?.zipURL,
            "https://github.com/agate/claude-lights/releases/download/v0.3.0/0.3.0.zip")
        XCTAssertEqual(r?.htmlURL,
            "https://github.com/agate/claude-lights/releases/tag/v0.3.0")
    }

    func testParseReleaseNoZipAsset() {
        let json = """
        {"tag_name":"v0.3.0","html_url":"https://x","assets":[{"name":"a.txt","browser_download_url":"https://x/a.txt"}]}
        """
        XCTAssertNil(ReleaseParser.parse(json))
    }

    func testParseReleaseGarbage() {
        XCTAssertNil(ReleaseParser.parse("not json"))
        XCTAssertNil(ReleaseParser.parse("{}"))
    }
}
