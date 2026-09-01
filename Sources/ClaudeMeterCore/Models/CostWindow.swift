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

    /// From the start of the **previous** UTC month up to the start of today.
    ///
    /// Reaching back a whole extra month lets the UI show last month's total beside this
    /// month's, and it incidentally removes the first-of-the-month edge case: the range can
    /// never collapse to zero length, which the API rejects with HTTP 400.
    ///
    /// A ~62-day span exceeds the API's 31-bucket cap, so the caller must follow
    /// `has_more`/`next_page` — verified 2026-09-01: Jul 1 → Sep 1 returns July, then August.
    public static func trailing(now: Date) -> CostWindow {
        let calendar = utcCalendar
        let end = calendar.startOfDay(for: now)
        let startOfMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now),
        ) ?? end
        let start = calendar.date(byAdding: .month, value: -1, to: startOfMonth) ?? startOfMonth
        return CostWindow(start: start, end: end)
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }
}
