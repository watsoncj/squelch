import XCTest
@testable import Squelch

final class UpdateCheckerTests: XCTestCase {

    // MARK: - Version comparison

    func testNewerPatchMinorMajor() {
        XCTAssertTrue(UpdateChecker.isNewer("1.8.1", than: "1.8.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.9.0", than: "1.8.0"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))
    }

    func testNumericNotLexicographic() {
        // "1.10.0" < "1.9.0" as strings — must compare numerically
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9.0", than: "1.10.0"))
    }

    func testEqualAndOlderAreNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.8.0", than: "1.8.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.7.9", than: "1.8.0"))
    }

    func testTagPrefixAndMissingComponents() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.9.0", than: "1.8.0"))
        XCTAssertEqual(UpdateChecker.normalized("v1.9.0"), "1.9.0")
        // "1.9" == "1.9.0"
        XCTAssertFalse(UpdateChecker.isNewer("1.9", than: "1.9.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.9.1", than: "1.9"))
    }

    // MARK: - Release feed parsing

    private func release(from json: String) throws -> UpdateChecker.Release {
        try JSONDecoder().decode(UpdateChecker.Release.self, from: Data(json.utf8))
    }

    func testDecodesGitHubReleaseShape() throws {
        let release = try release(from: """
        {
          "tag_name": "v1.9.0",
          "name": "Squelch 1.9.0",
          "assets": [
            {"name": "Squelch-1.9.0.zip",
             "browser_download_url": "https://github.com/watsoncj/squelch/releases/download/v1.9.0/Squelch-1.9.0.zip"}
          ]
        }
        """)
        XCTAssertEqual(release.tagName, "v1.9.0")
        XCTAssertEqual(UpdateChecker.zipAsset(in: release)?.name, "Squelch-1.9.0.zip")
    }

    func testZipAssetPrefersAppZipOverStrays() throws {
        let release = try release(from: """
        {
          "tag_name": "v1.9.0",
          "assets": [
            {"name": "dSYMs.zip", "browser_download_url": "https://example.com/dSYMs.zip"},
            {"name": "Squelch-1.9.0.zip", "browser_download_url": "https://example.com/app.zip"},
            {"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"}
          ]
        }
        """)
        XCTAssertEqual(UpdateChecker.zipAsset(in: release)?.name, "Squelch-1.9.0.zip")
    }

    func testZipAssetFallsBackToAnyZipAndNilWhenNone() throws {
        let stray = try release(from: """
        {"tag_name": "v1.9.0",
         "assets": [{"name": "build.zip", "browser_download_url": "https://example.com/build.zip"}]}
        """)
        XCTAssertEqual(UpdateChecker.zipAsset(in: stray)?.name, "build.zip")

        let none = try release(from: """
        {"tag_name": "v1.9.0", "assets": [{"name": "notes.txt", "browser_download_url": "https://example.com/n.txt"}]}
        """)
        XCTAssertNil(UpdateChecker.zipAsset(in: none))
    }
}
