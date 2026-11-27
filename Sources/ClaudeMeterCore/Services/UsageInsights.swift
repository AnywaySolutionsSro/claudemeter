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
            paceRatio: UsageStats.paceRatio(
                current: burn?.percentPerHour ?? 0,
                typical: UsageStats.typicalPercentPerHour(samples: history),
            ),
            trend: UsageStats.currentWindowTrend(samples: history),
        )
    }
}
