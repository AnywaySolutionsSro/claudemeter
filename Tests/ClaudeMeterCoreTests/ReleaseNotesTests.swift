@testable import ClaudeMeterCore
import XCTest

final class ReleaseNotesTests: XCTestCase {
    /// The body release.yml produces from PR "Release notes" sections.
    private let pipelineBody = """
    ## ✨ New
    - ✨ The dropdown header now shows which version you're running (#13)
    - 🎨 A friendlier update banner (#13)

    ## 🐛 Fixes
    - 🐛 The app comes back by itself after installing an update (#12)

    **Full Changelog**: https://github.com/AnywaySolutionsSro/claudemeter/compare/v01.02.01...v01.03.00
    """

    func testParsesSectionsAndBullets() {
        let notes = ReleaseNotes.parse(pipelineBody)
        XCTAssertEqual(notes.sections.map(\.title), ["✨ New", "🐛 Fixes"])
        XCTAssertEqual(notes.sections[0].items, [
            "✨ The dropdown header now shows which version you're running (#13)",
            "🎨 A friendlier update banner (#13)",
        ])
        XCTAssertEqual(notes.sections[1].items, ["🐛 The app comes back by itself after installing an update (#12)"])
        XCTAssertEqual(notes.allItems.count, 3)
        XCTAssertFalse(notes.isEmpty)
    }

    func testDropsGitHubBoilerplateAndAuthorSuffixes() {
        // GitHub's own --generate-notes shape (releases before the pipeline wrote notes).
        let body = """
        ## What's Changed
        * feat(updater): check GitHub daily and install updates in place by @jakubzak in https://github.com/x/y/pull/11
        * ci: release automatically on merge by @jakubzak in https://github.com/x/y/pull/10

        ## New Contributors
        * @dependabot made their first contribution in https://github.com/x/y/pull/6

        **Full Changelog**: https://github.com/x/y/compare/v01.01.00...v01.02.00
        """
        let notes = ReleaseNotes.parse(body)
        XCTAssertEqual(notes.sections.map(\.title), ["What's Changed"])
        XCTAssertEqual(notes.sections[0].items, [
            "feat(updater): check GitHub daily and install updates in place (#11)",
            "ci: release automatically on merge (#10)",
        ])
    }

    func testBulletsWithoutAHeadingLandInAnUntitledSection() {
        let notes = ReleaseNotes.parse("- ✨ one\n* 🐛 two\n\nsome prose that is not a bullet\n")
        XCTAssertEqual(notes.sections.count, 1)
        XCTAssertNil(notes.sections[0].title)
        XCTAssertEqual(notes.sections[0].items, ["✨ one", "🐛 two"])
    }

    func testEmptyAndNilBodies() {
        XCTAssertTrue(ReleaseNotes.parse("").isEmpty)
        XCTAssertTrue(ReleaseNotes.parse(nil).isEmpty)
        XCTAssertTrue(ReleaseNotes.parse("**Full Changelog**: https://x/compare/a...b").isEmpty)
        XCTAssertTrue(ReleaseNotes.parse("## Heading with nothing under it").isEmpty)
    }

    func testNormalizesWhitespaceAndWindowsLineEndings() {
        let notes = ReleaseNotes.parse("## 🐛 Fixes\r\n-   🐛 trimmed   \r\n")
        XCTAssertEqual(notes.sections[0].items, ["🐛 trimmed"])
    }
}
