@testable import ClaudeMeterCore
import XCTest

final class Sha256ManifestTests: XCTestCase {
    private let digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    func testParsesShasumOutput() {
        // `shasum -a 256 ClaudeMeter.zip` prints two spaces (text mode) or " *" (binary).
        XCTAssertEqual(Sha256Manifest.digest(in: "\(digest)  ClaudeMeter.zip\n", for: "ClaudeMeter.zip"), digest)
        XCTAssertEqual(Sha256Manifest.digest(in: "\(digest) *ClaudeMeter.zip", for: "ClaudeMeter.zip"), digest)
        XCTAssertEqual(
            Sha256Manifest.digest(in: digest.uppercased() + "  ClaudeMeter.zip", for: "ClaudeMeter.zip"),
            digest,
        )
    }

    func testPicksTheNamedFileAmongSeveralLines() {
        let text = """
        1111111111111111111111111111111111111111111111111111111111111111  other.zip
        \(digest)  ClaudeMeter.zip
        """
        XCTAssertEqual(Sha256Manifest.digest(in: text, for: "ClaudeMeter.zip"), digest)
        XCTAssertNil(Sha256Manifest.digest(in: text, for: "missing.zip"))
    }

    func testRejectsMalformedDigests() {
        XCTAssertNil(Sha256Manifest.digest(in: "", for: "ClaudeMeter.zip"))
        XCTAssertNil(Sha256Manifest.digest(in: "abc  ClaudeMeter.zip", for: "ClaudeMeter.zip"))
        XCTAssertNil(Sha256Manifest.digest(in: "\(digest)ClaudeMeter.zip", for: "ClaudeMeter.zip"))
        XCTAssertNil(Sha256Manifest.digest(in: "zz" + String(digest.dropFirst(2)) + "  ClaudeMeter.zip",
                                           for: "ClaudeMeter.zip"))
    }

    func testHexDigestOfData() {
        XCTAssertEqual(Sha256Manifest.hexDigest(of: Data()), digest)
        XCTAssertEqual(
            Sha256Manifest.hexDigest(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        )
    }

    func testMatchesIsCaseInsensitive() {
        XCTAssertTrue(Sha256Manifest.matches(expected: digest.uppercased(), data: Data()))
        XCTAssertFalse(Sha256Manifest.matches(expected: digest, data: Data("x".utf8)))
    }
}
