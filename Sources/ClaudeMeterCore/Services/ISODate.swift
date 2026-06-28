import Foundation

/// Parses the ISO-8601 timestamps returned by the usage API, e.g.
/// `2026-06-27T16:19:59.398499+00:00`.
///
/// `ISO8601DateFormatter` only reliably handles millisecond (3-digit) fractional seconds,
/// but the API emits microseconds (6 digits). Since sub-second precision is irrelevant for a
/// reset countdown, we strip the fractional component entirely before parsing.
enum ISODate {
    // ISO8601DateFormatter is a class with mutable config, but we only read from it
    // (`date(from:)`), which is safe to share. nonisolated(unsafe) opts out of the check.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ string: String) -> Date? {
        formatter.date(from: stripFractionalSeconds(string))
    }

    /// Removes a `.NNN…` fractional-seconds group while preserving the timezone suffix
    /// (`Z` or `+00:00`).
    private static func stripFractionalSeconds(_ string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        var end = string.index(after: dot)
        while end < string.endIndex, string[end].isNumber {
            end = string.index(after: end)
        }
        var result = string
        result.removeSubrange(dot..<end)
        return result
    }
}
