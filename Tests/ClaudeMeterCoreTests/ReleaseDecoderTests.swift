@testable import ClaudeMeterCore
import XCTest

final class ReleaseDecoderTests: XCTestCase {
    private let decoder = ReleaseDecoder()

    /// The shape of `GET /repos/{owner}/{repo}/releases/latest` for a release
    /// published by release.yml, trimmed to the keys that matter plus noise.
    private let realShape = Data("""
    {
      "url": "https://api.github.com/repos/AnywaySolutionsSro/claudemeter/releases/1",
      "html_url": "https://github.com/AnywaySolutionsSro/claudemeter/releases/tag/v01.02.00",
      "id": 1, "node_id": "RE_x", "author": { "login": "github-actions[bot]" },
      "tag_name": "v01.02.00",
      "target_commitish": "main",
      "name": "ClaudeMeter 01.02.00",
      "draft": false,
      "prerelease": false,
      "published_at": "2026-08-29T12:34:56Z",
      "assets": [
        { "name": "ClaudeMeter.zip.sha256", "size": 87, "content_type": "application/octet-stream",
          "browser_download_url": "https://github.com/AnywaySolutionsSro/claudemeter/releases/download/v01.02.00/ClaudeMeter.zip.sha256" },
        { "name": "ClaudeMeter.zip", "size": 1234567, "content_type": "application/zip",
          "browser_download_url": "https://github.com/AnywaySolutionsSro/claudemeter/releases/download/v01.02.00/ClaudeMeter.zip" }
      ],
      "body": "## What's Changed\\n* feat(updater): self-update by @jakubzak in #11"
    }
    """.utf8)

    func testDecodesARealRelease() throws {
        let release = try XCTUnwrap(decoder.decode(realShape))

        XCTAssertEqual(release.version, AppVersion(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(release.tagName, "v01.02.00")
        XCTAssertEqual(release.pageURL.absoluteString,
                       "https://github.com/AnywaySolutionsSro/claudemeter/releases/tag/v01.02.00")
        XCTAssertEqual(release.archiveURL.lastPathComponent, "ClaudeMeter.zip")
        XCTAssertEqual(release.checksumURL?.lastPathComponent, "ClaudeMeter.zip.sha256")
        XCTAssertEqual(release.archiveSize, 1_234_567)
        XCTAssertEqual(release.notes, "## What's Changed\n* feat(updater): self-update by @jakubzak in #11")
        XCTAssertEqual(release.publishedAt, ISODate.parse("2026-08-29T12:34:56Z"))
    }

    func testChecksumIsOptionalButArchiveIsNot() throws {
        let noChecksum = try XCTUnwrap(decoder.decode(json(assets: [("ClaudeMeter.zip", "https://x/ClaudeMeter.zip")])))
        XCTAssertNil(noChecksum.checksumURL)
        XCTAssertNotNil(noChecksum.archiveURL)

        XCTAssertNil(decoder.decode(json(assets: [("ClaudeMeter.zip.sha256", "https://x/ClaudeMeter.zip.sha256")])))
        XCTAssertNil(decoder.decode(json(assets: [])))
    }

    func testIgnoresOtherAssetsAndPicksByExactName() throws {
        let release = try XCTUnwrap(decoder.decode(json(assets: [
            ("ClaudeMeter-symbols.zip", "https://x/ClaudeMeter-symbols.zip"),
            ("claudemeter.zip", "https://x/lowercase.zip"),
            ("ClaudeMeter.zip", "https://x/right.zip"),
        ])))
        XCTAssertEqual(release.archiveURL.absoluteString, "https://x/right.zip")
    }

    func testRejectsDraftsPrereleasesAndUnparsableTags() {
        XCTAssertNil(decoder.decode(json(tag: "v01.02.00", draft: true)))
        XCTAssertNil(decoder.decode(json(tag: "v01.02.00", prerelease: true)))
        XCTAssertNil(decoder.decode(json(tag: "v01.02.00-rc1")))
        XCTAssertNil(decoder.decode(json(tag: "latest")))
        XCTAssertNil(decoder.decode(json(tag: "")))
    }

    func testToleratesMissingOptionalFieldsAndUnknownShapes() throws {
        let minimal = try XCTUnwrap(decoder.decode(Data("""
        { "tag_name": "v03.00.00", "html_url": "https://x/tag",
          "assets": [ { "name": "ClaudeMeter.zip", "browser_download_url": "https://x/a.zip" } ] }
        """.utf8)))
        XCTAssertNil(minimal.notes)
        XCTAssertNil(minimal.publishedAt)
        XCTAssertNil(minimal.archiveSize)

        XCTAssertNil(decoder.decode(Data("not json".utf8)))
        XCTAssertNil(decoder.decode(Data("[]".utf8)))
        XCTAssertNil(decoder.decode(Data(#"{ "message": "Not Found" }"#.utf8)))
        XCTAssertNil(decoder.decode(Data(#"{ "tag_name": "v01.00.00", "assets": "nope" }"#.utf8)))
    }

    // MARK: - Helpers

    private func json(
        tag: String = "v01.02.00",
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [(String, String)] = [("ClaudeMeter.zip", "https://x/ClaudeMeter.zip")],
    ) -> Data {
        let assetJSON = assets.map { #"{ "name": "\#($0.0)", "browser_download_url": "\#($0.1)" }"# }
            .joined(separator: ",")
        return Data("""
        { "tag_name": "\(tag)", "html_url": "https://x/tag/\(tag)", "draft": \(draft),
          "prerelease": \(prerelease), "assets": [\(assetJSON)] }
        """.utf8)
    }
}
