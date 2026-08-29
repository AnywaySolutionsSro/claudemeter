import Foundation

/// Everything that can go wrong between "check GitHub" and "relaunch the new build".
/// Messages are user-facing (shown in the dropdown and in the failure notification).
enum UpdateError: LocalizedError, Equatable {
    case network(String)
    case httpStatus(Int)
    case malformedRelease
    case checksumMalformed
    case checksumMismatch
    case unpackFailed(String)
    case bundleMissing
    case signatureInvalid(String)
    case versionMismatch(expected: String, found: String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case let .network(detail): "Couldn't reach GitHub: \(detail)"
        case let .httpStatus(code): "GitHub answered HTTP \(code)."
        case .malformedRelease: "The latest release on GitHub is missing ClaudeMeter.zip."
        case .checksumMalformed: "The release's checksum file is unreadable."
        case .checksumMismatch: "The download's checksum doesn't match the release — not installed."
        case let .unpackFailed(detail): "Couldn't unpack the download: \(detail)"
        case .bundleMissing: "The download didn't contain ClaudeMeter.app."
        case let .signatureInvalid(detail): "The download isn't signed by ClaudeMeter's developer — not installed. (\(detail))"
        case let .versionMismatch(expected, found):
            "The downloaded app reports version \(found), expected \(expected) — not installed."
        case let .installFailed(detail): "Couldn't replace the installed app: \(detail)"
        }
    }
}
