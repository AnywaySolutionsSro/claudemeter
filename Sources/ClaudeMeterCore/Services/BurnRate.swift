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
    /// Estimate burn from recent samples in the *current* session window.
    ///
    /// Uses samples sharing the latest sample's `sessionResetsAt` (so a window reset doesn't
    /// look like negative burn) within the trailing `lookback`. Needs ≥ 2 spaced samples.
    public static func estimate(
        samples: [UsageSample],
        now: Date,
        lookback: TimeInterval = 3600
    ) -> BurnEstimate? {
        guard let latest = samples.max(by: { $0.timestamp < $1.timestamp }) else { return nil }

        let currentWindow = samples
            .filter { $0.sessionResetsAt == latest.sessionResetsAt }
            .filter { now.timeIntervalSince($0.timestamp) <= lookback }
            .sorted { $0.timestamp < $1.timestamp }

        guard let first = currentWindow.first, let last = currentWindow.last,
              first.timestamp < last.timestamp else { return nil }

        let hours = last.timestamp.timeIntervalSince(first.timestamp) / 3600
        guard hours > 0 else { return nil }

        let delta = last.sessionUtilization - first.sessionUtilization
        let rate = max(0, delta / hours)

        guard rate > 0.01 else { return BurnEstimate(percentPerHour: 0, etaToLimit: nil) }

        let remaining = max(0, 100 - last.sessionUtilization)
        let eta = remaining / rate * 3600
        return BurnEstimate(percentPerHour: rate, etaToLimit: eta)
    }
}
