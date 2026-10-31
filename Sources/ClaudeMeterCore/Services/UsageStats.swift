import Foundation

/// A window that passed a usage threshold between two readings.
public struct WindowCrossing: Equatable, Sendable {
    public let window: LimitWindow
    public let threshold: Double

    public init(window: LimitWindow, threshold: Double) {
        self.window = window
        self.threshold = threshold
    }
}

/// Pure helpers for history-derived stats and event detection.
public enum UsageStats {
    /// Median positive burn rate (%/hour) across all of history — the user's "usual" pace.
    /// Returns `nil` until there's enough signal.
    public static func typicalPercentPerHour(samples: [UsageSample]) -> Double? {
        // Only the window type in use now: session rates dwarf weekly ones, so a median
        // across both says nothing after an account loses its session window.
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        let sorted = ordered.filter { $0.tracksSession == ordered.last?.tracksSession }
        var rates: [Double] = []

        for (a, b) in zip(sorted, sorted.dropFirst()) {
            guard a.isSameWindow(as: b) else { continue }
            let hours = b.timestamp.timeIntervalSince(a.timestamp) / 3600
            guard hours > 0 else { continue }
            let rate = (b.trackedUtilization - a.trackedUtilization) / hours
            if rate > 0.01 { rates.append(rate) }
        }

        guard !rates.isEmpty else { return nil }
        rates.sort()
        let mid = rates.count / 2
        return rates.count.isMultiple(of: 2) ? (rates[mid - 1] + rates[mid]) / 2 : rates[mid]
    }

    /// The current window's readings, oldest first, for a sparkline.
    public static func currentWindowTrend(samples: [UsageSample]) -> [Double] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        guard let latest = sorted.last else { return [] }
        return sorted.filter { $0.isSameWindow(as: latest) }.map(\.trackedUtilization)
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

    /// The highest threshold each window newly crossed, in window order. Windows are
    /// matched by identity; one with no prior reading has crossed nothing.
    public static func crossedWindows(
        previous: [LimitWindow],
        current: [LimitWindow],
        thresholds: [Double],
    ) -> [WindowCrossing] {
        current.compactMap { window in
            guard
                let before = previous.first(where: { $0.id == window.id }),
                let highest = crossedThresholds(
                    previous: before.bucket.utilization,
                    current: window.bucket.utilization,
                    thresholds: thresholds,
                ).last
            else {
                return nil
            }
            return WindowCrossing(window: window, threshold: highest)
        }
    }

    /// The windows that refilled between two readings. Each is compared only with
    /// itself: a session window vanishing mid-run must not read as a drop to the
    /// weekly figure.
    public static func refilledWindows(
        previous: [LimitWindow],
        current: [LimitWindow],
        dropThreshold: Double = 25,
    ) -> [LimitWindow] {
        current.filter { window in
            guard let before = previous.first(where: { $0.id == window.id }) else { return false }
            return didRefill(
                previousUtilization: before.bucket.utilization,
                currentUtilization: window.bucket.utilization,
                dropThreshold: dropThreshold,
            )
        }
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

    /// A window with nothing left (utilization at or past 100%). `nil` — no such
    /// bucket in the reading — is not exhausted.
    public static func isExhausted(_ utilization: Double?) -> Bool {
        guard let utilization else { return false }
        return utilization >= 100
    }

    /// Count of distinct session windows that reached `>= maxedAt`% within `since`.
    public static func maxedWindows(
        samples: [UsageSample],
        since: Date,
        maxedAt: Double = 95,
    ) -> Int {
        let reset = Set(
            samples
                .filter { $0.timestamp >= since && ($0.sessionUtilization ?? 0) >= maxedAt }
                .compactMap(\.sessionResetsAt),
        )
        return reset.count
    }
}
