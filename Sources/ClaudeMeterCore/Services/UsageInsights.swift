import Foundation

/// What the dropdown's insight lines and sparkline need from a usage history: the
/// burn rate, the pace against the user's usual, and the current window's trend.
public struct UsageInsights: Equatable, Sendable {
    /// The samples these were computed from, oldest first.
    public let history: [UsageSample]
    public let burn: BurnEstimate?
    /// Current burn relative to the typical one (2.1 == 2.1× as fast), when known.
    public let paceRatio: Double?
    /// The current window's readings, oldest first, for the sparkline.
    public let trend: [Double]

    public static let empty = UsageInsights(history: [], burn: nil, paceRatio: nil, trend: [])

    public init(history: [UsageSample], burn: BurnEstimate?, paceRatio: Double?, trend: [Double]) {
        self.history = history
        self.burn = burn
        self.paceRatio = paceRatio
        self.trend = trend
    }

    /// The same derivation Claude's `UsageStore` makes, for any history.
    public static func compute(history: [UsageSample], now: Date) -> UsageInsights {
        let burn = BurnRate.estimate(samples: history, now: now)
        return UsageInsights(
            history: history,
            burn: burn,
            paceRatio: paceRatio(history: history, burn: burn),
            trend: UsageStats.currentWindowTrend(samples: history),
        )
    }

    /// History shorter than this is no "usual pace" to compare against: a first
    /// half-hour's median rate reads as a meaningless "0.0× your usual pace".
    public static let paceBaselineSpan: TimeInterval = 24 * 3600

    /// Current burn relative to the typical one, or `nil` while there is no baseline:
    /// under `paceBaselineSpan` of history, or no typical rate to divide by.
    public static func paceRatio(history: [UsageSample], burn: BurnEstimate?) -> Double? {
        guard hasPaceBaseline(history) else { return nil }
        return UsageStats.paceRatio(
            current: burn?.percentPerHour ?? 0,
            typical: UsageStats.typicalPercentPerHour(samples: history),
        )
    }

    /// Whether `history` spans at least `paceBaselineSpan`.
    public static func hasPaceBaseline(_ history: [UsageSample]) -> Bool {
        let times = history.map(\.timestamp)
        guard let first = times.min(), let last = times.max() else { return false }
        return last.timeIntervalSince(first) >= paceBaselineSpan
    }
}
