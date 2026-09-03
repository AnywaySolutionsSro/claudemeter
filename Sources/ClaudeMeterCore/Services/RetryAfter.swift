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

    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
