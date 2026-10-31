import Foundation

/// How this week's usage compares with an even spread over the week. A weekly window
/// has a fixed length and reset, so this needs no history, unlike `BurnRate`.
public struct WeeklyPace: Equatable, Sendable {
    /// Where an even spread would be by now (0...100).
    public let expectedPercent: Double
    /// Seconds until the limit at this week's average rate, when that is meaningfully
    /// before the reset; `nil` means on track.
    public let runsOutIn: TimeInterval?

    private static let week: TimeInterval = 7 * 24 * 3600
    /// One long first day shouldn't produce a verdict about the whole week.
    private static let minimumElapsed: TimeInterval = 12 * 3600
    /// Percentage points ahead of an even spread that still count as on track.
    private static let tolerance = 5.0

    /// `nil` when there's no verdict to give: no reset date, a window that isn't a
    /// week long, too early in the week, or already exhausted.
    public static func estimate(_ bucket: UsageBucket, now: Date) -> WeeklyPace? {
        guard
            let left = bucket.timeUntilReset(now: now), left > 0, left <= week,
            !UsageStats.isExhausted(bucket.utilization)
        else {
            return nil
        }
        let elapsed = week - left
        guard elapsed >= minimumElapsed else { return nil }

        let used = bucket.utilization
        let expected = elapsed / week * 100
        guard used - expected > tolerance else {
            return WeeklyPace(expectedPercent: expected, runsOutIn: nil)
        }
        let eta = (100 - used) / (used / elapsed)
        return WeeklyPace(expectedPercent: expected, runsOutIn: eta < left ? eta : nil)
    }
}
