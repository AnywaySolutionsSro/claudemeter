import ClaudeMeterCore
import Foundation
import Security

/// The updater's trust gate. A downloaded bundle is installed only if macOS's own
/// code-signing machinery confirms it is a valid **Developer ID** build by *this*
/// team, with *this* bundle identifier, whose nested code (the widget appex) is
/// intact — and its Info.plist carries the version the release claims. A sha256
/// match only proves the download is what GitHub served; this proves who built it.
enum BundleVerifier {
    static let teamID = "72K9YQF24J"
    static let bundleID = "com.jakubzak.claudemeter"

    /// Developer ID Application certificates: issued under Apple's root, through
    /// the Developer ID intermediate (`1.2.840.113635.100.6.2.6`), leaf marked
    /// `1.2.840.113635.100.6.1.13`, and the OU is the team ID. A bare field
    /// designator means "this field exists" — the same form `codesign -dr -`
    /// prints as the designated requirement of a Developer ID build.
    static let requirement =
        "anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
            + " and identifier \"\(bundleID)\""

    static func verify(bundleURL: URL, expectedVersion: AppVersion) throws {
        try verifySignature(bundleURL: bundleURL)
        try verifyInfoPlist(bundleURL: bundleURL, expectedVersion: expectedVersion)
    }

    private static func verifySignature(bundleURL: URL) throws {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard created == errSecSuccess, let code = staticCode else {
            throw UpdateError.signatureInvalid("SecStaticCodeCreateWithPath \(created)")
        }
        var requirement: SecRequirement?
        let parsed = SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement)
        guard parsed == errSecSuccess, let requirement else {
            throw UpdateError.signatureInvalid("SecRequirementCreateWithString \(parsed)")
        }
        var error: Unmanaged<CFError>?
        // Revocation is enforced (one OCSP round-trip per install): the updater writes the
        // bundle without quarantine, so Gatekeeper never assesses it — this check is the
        // only thing standing between a revoked Developer ID key and a silent install.
        // `kSecCSEnforceRevocationChecks` (CSCommon.h, 1 << 30) isn't imported into Swift.
        let enforceRevocationChecks: UInt32 = 1 << 30
        let flags = SecCSFlags(
            rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSCheckAllArchitectures
                | enforceRevocationChecks,
        )
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        guard status == errSecSuccess else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "OSStatus \(status)"
            throw UpdateError.signatureInvalid(detail)
        }
    }

    private static func verifyInfoPlist(bundleURL: URL, expectedVersion: AppVersion) throws {
        guard let bundle = Bundle(url: bundleURL) else { throw UpdateError.bundleMissing }
        guard bundle.bundleIdentifier == bundleID else {
            throw UpdateError.signatureInvalid("bundle identifier \(bundle.bundleIdentifier ?? "?")")
        }
        let found = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        guard AppVersion(found) == expectedVersion else {
            throw UpdateError.versionMismatch(expected: expectedVersion.description, found: found)
        }
    }
}
