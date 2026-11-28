import Foundation

/// Turns Codex limit readings (from local transcripts) into a `UsageSnapshot`, so the
/// existing gauges, alerts and refill detection work on them unchanged.
///
/// The snapshot is Codex's own: never merge its windows with Claude's — both have a
/// "Weekly" window and `LimitWindow.id` is only a label.
public enum CodexLimits {
    /// Windows this long or shorter are the session window.
    static let sessionMaxMinutes = 300
    /// Windows this long or longer are the weekly window.
    static let weeklyMinMinutes = 10080
    /// The main Codex allowance's `limit_id`.
    static let primaryLimitID = "codex"

    /// The reading to show: the newest `"codex"` reading when there is one, else the
    /// newest reading of any limit.
    public static func newest(_ readings: [CodexLimitReading]) -> CodexLimitReading? {
        let main = readings.filter { $0.limitID == primaryLimitID }
        return (main.isEmpty ? readings : main).max { $0.observedAt < $1.observedAt }
    }

    /// The reading as a snapshot at `now`. Window identity comes from its length, never
    /// its `primary`/`secondary` position: ≤ 300 min → `fiveHour`, ≥ 10080 → `sevenDay`,
    /// any other length → `sevenDay` when no weekly window claims it, else ignored.
    ///
    /// A window whose reset has passed reads as **full** (0% used): no Codex turn runs
    /// while blocked, so no newer reading arrives to say so. This is also what makes
    /// the passing reset look like a refill to `UsageStats.refilledWindows`.
    /// `fetchedAt` is when the reading was observed, not `now`.
    public static func snapshot(from reading: CodexLimitReading, now: Date) -> UsageSnapshot {
        var session: UsageBucket?
        var weekly: UsageBucket?
        var other: UsageBucket?
        for window in reading.windows {
            let bucket = bucket(window, now: now)
            if window.windowMinutes <= sessionMaxMinutes {
                session = session ?? bucket
            } else if window.windowMinutes >= weeklyMinMinutes {
                weekly = weekly ?? bucket
            } else {
                other = other ?? bucket
            }
        }
        return UsageSnapshot(
            fiveHour: session, sevenDay: weekly ?? other,
            sevenDayOpus: nil, sevenDaySonnet: nil, fetchedAt: reading.observedAt,
        )
    }

    /// The window's reset has passed with no newer reading — shown as "reset at …
    /// · no reading since".
    public static func isPastReset(_ window: CodexWindowReading, now: Date) -> Bool {
        guard let resetsAt = window.resetsAt else { return false }
        return resetsAt <= now
    }

    private static func bucket(_ window: CodexWindowReading, now: Date) -> UsageBucket {
        UsageBucket(
            utilization: isPastReset(window, now: now) ? 0 : window.usedPercent,
            resetsAt: window.resetsAt,
        )
    }
}
