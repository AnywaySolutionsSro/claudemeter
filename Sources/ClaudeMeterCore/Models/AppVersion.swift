import Foundation

/// A release version in this project's `MM.mm.pp` scheme (two-digit, zero-padded,
/// e.g. `01.02.03`; release tags prefix a `v`). Parsed numerically, so ordering is
/// `01.09.00 < 01.10.00`. No pre-release suffixes: the release pipeline only
/// publishes plain versions and anything else must not be offered as an update.
public struct AppVersion: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Accepts `MM.mm.pp`, `vMM.mm.pp`, unpadded `1.2.3`; surrounding whitespace ignored.
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    /// `01.02.03` — what `CFBundleShortVersionString` carries.
    public var description: String {
        String(format: "%02d.%02d.%02d", major, minor, patch)
    }

    /// `v01.02.03` — the git tag / GitHub release name.
    public var tagName: String { "v\(description)" }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
