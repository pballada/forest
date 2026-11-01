import Foundation
import Testing
@testable import ForestCore

@Suite struct UpdateFeedTests {
    @Test func comparesVersionsNumerically() {
        #expect(UpdateFeed.isNewer("0.10.0", than: "0.9.3"))
        #expect(UpdateFeed.isNewer("0.2.1", than: "0.2.0"))
        #expect(UpdateFeed.isNewer("1.0", than: "0.99.99"))
        #expect(!UpdateFeed.isNewer("1.0", than: "1.0.0"))
        #expect(!UpdateFeed.isNewer("0.2.0", than: "0.3.0"))
    }

    @Test func parsesLatestRelease() throws {
        let json = """
        {"tag_name": "v0.3.0", "body": "### New\\n- Updates", "html_url": "https://github.com/pballada/forest/releases/tag/v0.3.0",
         "draft": false, "prerelease": false,
         "assets": [
           {"name": "Forest-0.3.0.dmg", "browser_download_url": "https://example.com/Forest-0.3.0.dmg", "size": 10},
           {"name": "Forest-0.3.0.zip", "browser_download_url": "https://example.com/Forest-0.3.0.zip", "size": 20}
         ]}
        """
        let release = try #require(UpdateFeed.parse(Data(json.utf8)))
        #expect(release.version == "0.3.0")
        #expect(release.archive.lastPathComponent == "Forest-0.3.0.zip")
        #expect(release.archiveSize == 20)
    }

    @Test func ignoresPrereleasesAndReleasesWithoutZip() {
        let prerelease = """
        {"tag_name": "v0.4.0", "html_url": "https://x.y", "prerelease": true,
         "assets": [{"name": "Forest-0.4.0.zip", "browser_download_url": "https://x.y/a.zip", "size": 1}]}
        """
        let noZip = """
        {"tag_name": "v0.4.0", "html_url": "https://x.y", "assets": [{"name": "Forest.dmg", "browser_download_url": "https://x.y/a.dmg", "size": 1}]}
        """
        #expect(UpdateFeed.parse(Data(prerelease.utf8)) == nil)
        #expect(UpdateFeed.parse(Data(noZip.utf8)) == nil)
    }
}
