import Foundation

/// The UTC date range to request from the Cost API.
///
/// The API reports **completed UTC days only**: it clamps `ending_at` to the start of the
/// current day, and rejects a range that then collapses to zero length with HTTP 400
/// ("Invalid date range: ending date must be after starting date"). Verified 2026-09-01 —
/// a request for Aug 30 → Sep 02 returns only the Aug 30 and Aug 31 buckets.
///
/// So the window always ends at today 00:00 UTC, and always starts at least one full day
/// before that. Without the second rule, month-to-date on the **first of the month** is an
/// empty range and the whole feature fails with a 400.
public struct CostWindow: Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public static func monthToDate(now: Date) -> CostWindow {
        let calendar = utcCalendar
        let end = calendar.startOfDay(for: now)
        let startOfMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now),
        ) ?? end
        // On the 1st, the month has no completed days yet — reach back a day so the request
        // stays valid and the most recent completed day is still reported.
        let previousDay = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        return CostWindow(start: min(startOfMonth, previousDay), end: end)
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }
}
