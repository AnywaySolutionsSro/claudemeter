import Foundation

/// Pure helpers for history-derived stats and event detection.
public enum UsageStats {
    /// Median positive burn rate (%/hour) across all of history — the user's "usual" pace.
    /// Returns `nil` until there's enough signal.
    public static func typicalPercentPerHour(samples: [UsageSample]) -> Double? {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        var rates: [Double] = []

        for (a, b) in zip(sorted, sorted.dropFirst()) {
            guard a.sessionResetsAt == b.sessionResetsAt else { continue } // same window only
            let hours = b.timestamp.timeIntervalSince(a.timestamp) / 3600
            guard hours > 0 else { continue }
            let rate = (b.sessionUtilization - a.sessionUtilization) / hours
            if rate > 0.01 { rates.append(rate) }
        }

        guard !rates.isEmpty else { return nil }
        rates.sort()
        let mid = rates.count / 2
        return rates.count.isMultiple(of: 2) ? (rates[mid - 1] + rates[mid]) / 2 : rates[mid]
    }

    /// Current pace relative to the user's typical pace (e.g. 2.1 == burning 2.1× as fast).
    public static func paceRatio(current: Double, typical: Double?) -> Double? {
        guard let typical, typical > 0.01, current > 0.01 else { return nil }
        return current / typical
    }

    /// Thresholds (e.g. 80/90/100) newly crossed upward between two readings.
    public static func crossedThresholds(
        previous: Double?,
        current: Double,
        thresholds: [Double],
    ) -> [Double] {
        let previous = previous ?? -1
        return thresholds.filter { $0 > previous && $0 <= current }.sorted()
    }

    /// A window refilled when utilization drops sharply between two readings — the only
    /// reliable signal, since `resets_at` creeps forward continuously and would false-trigger.
    public static func didRefill(
        previousUtilization: Double?,
        currentUtilization: Double,
        dropThreshold: Double = 25,
    ) -> Bool {
        guard let previous = previousUtilization else { return false }
        return previous - currentUtilization >= dropThreshold
    }

    /// Count of distinct session windows that reached `>= maxedAt`% within `since`.
    public static func maxedWindows(
        samples: [UsageSample],
        since: Date,
        maxedAt: Double = 95,
    ) -> Int {
        let reset = Set(
            samples
                .filter { $0.timestamp >= since && $0.sessionUtilization >= maxedAt }
                .compactMap(\.sessionResetsAt),
        )
        return reset.count
    }
}
