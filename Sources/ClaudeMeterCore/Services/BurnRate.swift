import Foundation

/// How fast the session window is being consumed, and when it will run out.
public struct BurnEstimate: Equatable, Sendable {
    /// Percentage points consumed per hour (≥ 0; 0 when idle or refilling).
    public let percentPerHour: Double
    /// Seconds until the window hits 100% at the current rate, or `nil` if not burning.
    public let etaToLimit: TimeInterval?

    public init(percentPerHour: Double, etaToLimit: TimeInterval?) {
        self.percentPerHour = percentPerHour
        self.etaToLimit = etaToLimit
    }

    public var isBurning: Bool { percentPerHour > 0.01 }
}

public enum BurnRate {
    /// Minimum span of data before a rate is reported, to avoid wild early estimates.
    public static let minimumSpan: TimeInterval = 300

    /// Estimate burn from recent samples in the *current* session window.
    ///
    /// Uses a least-squares trend over all in-window samples within the trailing `lookback`
    /// (smoothing out the noise a two-point delta would amplify). Only samples sharing the
    /// latest `sessionResetsAt` are considered, so a window reset never looks like burn.
    public static func estimate(
        samples: [UsageSample],
        now: Date,
        lookback: TimeInterval = 3600,
    ) -> BurnEstimate? {
        guard let latest = samples.max(by: { $0.timestamp < $1.timestamp }) else { return nil }

        let window = samples
            .filter { $0.sessionResetsAt == latest.sessionResetsAt }
            .filter { now.timeIntervalSince($0.timestamp) <= lookback }
            .sorted { $0.timestamp < $1.timestamp }

        guard window.count >= 2, let first = window.first, let last = window.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= minimumSpan else { return nil }

        guard let slope = leastSquaresSlopePerHour(window, origin: first.timestamp) else {
            return BurnEstimate(percentPerHour: 0, etaToLimit: nil)
        }
        let rate = max(0, slope)
        guard rate > 0.01 else { return BurnEstimate(percentPerHour: 0, etaToLimit: nil) }

        let remaining = max(0, 100 - last.sessionUtilization)
        return BurnEstimate(percentPerHour: rate, etaToLimit: remaining / rate * 3600)
    }

    /// Slope of utilization vs. time (percentage points per hour), or `nil` if degenerate.
    private static func leastSquaresSlopePerHour(_ samples: [UsageSample], origin: Date) -> Double? {
        let xs = samples.map { $0.timestamp.timeIntervalSince(origin) / 3600 }
        let ys = samples.map(\.sessionUtilization)
        let n = Double(samples.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n

        var covariance = 0.0
        var varianceX = 0.0
        for (x, y) in zip(xs, ys) {
            covariance += (x - meanX) * (y - meanY)
            varianceX += (x - meanX) * (x - meanX)
        }
        guard varianceX > 0 else { return nil }
        return covariance / varianceX
    }
}
