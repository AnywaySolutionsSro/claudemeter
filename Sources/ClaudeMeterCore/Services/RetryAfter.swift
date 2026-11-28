import Foundation

/// Parses an HTTP `Retry-After` header into a positive delay in seconds.
/// Accepts both forms the spec allows: delay-seconds and an IMF-fixdate.
public enum RetryAfter {
    public static func seconds(_ header: String, now: Date = Date()) -> TimeInterval? {
        let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let delay = TimeInterval(value) {
            return delay > 0 ? delay : nil
        }
        guard let date = httpDate.date(from: value) else { return nil }
        let delay = date.timeIntervalSince(now)
        return delay > 0 ? delay : nil
    }

    /// Bounds for a server-supplied delay. A huge or non-finite value (`inf`, `1e400`)
    /// must never reach an `Int` conversion or park polling for days.
    public static let minimumDelay: TimeInterval = 1
    public static let maximumDelay: TimeInterval = 3600
    public static let defaultDelay: TimeInterval = 60

    /// `seconds` clamped to 1 s…1 h; missing, non-finite or non-positive → 60 s.
    public static func clamped(_ seconds: TimeInterval?) -> TimeInterval {
        guard let seconds, seconds.isFinite, seconds > 0 else { return defaultDelay }
        return min(max(seconds, minimumDelay), maximumDelay)
    }

    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
