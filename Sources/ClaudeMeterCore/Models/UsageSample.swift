import Foundation

/// A single timestamped reading, persisted to build history for burn-rate, sparklines,
/// averages, and reset/threshold detection.
///
/// Stored fields only ever gain optionals: `UsageHistory` decodes the file all-or-nothing,
/// so a field earlier versions didn't write must not be required.
public struct UsageSample: Codable, Equatable, Sendable {
    public let timestamp: Date
    /// Percent used (0–100) of the 5-hour session window; `nil` on accounts without one.
    public let sessionUtilization: Double?
    /// When the current session window resets — used to tell windows apart.
    public let sessionResetsAt: Date?
    /// Percent used of the weekly window, if present.
    public let weeklyUtilization: Double?
    /// When the current weekly window resets. Absent from samples of earlier versions.
    public let weeklyResetsAt: Date?

    /// Weekly `resets_at` values within this of each other are the same window: the
    /// field carries sub-second noise, while a real rollover moves it by a week.
    private static let weeklyResetTolerance: TimeInterval = 3600

    public init(
        timestamp: Date,
        sessionUtilization: Double?,
        sessionResetsAt: Date?,
        weeklyUtilization: Double?,
        weeklyResetsAt: Date? = nil,
    ) {
        self.timestamp = timestamp
        self.sessionUtilization = sessionUtilization
        self.sessionResetsAt = sessionResetsAt
        self.weeklyUtilization = weeklyUtilization
        self.weeklyResetsAt = weeklyResetsAt
    }

    /// True when the session window drives this sample, false when the weekly one does.
    public var tracksSession: Bool { sessionUtilization != nil }

    /// Percent used of the window this sample tracks: the same one the menu bar shows.
    public var trackedUtilization: Double { sessionUtilization ?? weeklyUtilization ?? 0 }

    /// Whether two samples read the same window instance, so a trend across them means
    /// something. A session reading and a weekly one are never comparable.
    public func isSameWindow(as other: UsageSample) -> Bool {
        guard tracksSession == other.tracksSession else { return false }
        if tracksSession { return sessionResetsAt == other.sessionResetsAt }
        guard let weeklyResetsAt, let otherReset = other.weeklyResetsAt else {
            return weeklyResetsAt == other.weeklyResetsAt
        }
        return abs(weeklyResetsAt.timeIntervalSince(otherReset)) < Self.weeklyResetTolerance
    }
}

public extension UsageSnapshot {
    /// Capture the parts of a snapshot worth keeping in history. `nil` only when the
    /// reading has neither an account-wide window to track.
    func sample(at timestamp: Date) -> UsageSample? {
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return UsageSample(
            timestamp: timestamp,
            sessionUtilization: fiveHour?.utilization,
            sessionResetsAt: fiveHour?.resetsAt,
            weeklyUtilization: sevenDay?.utilization,
            weeklyResetsAt: sevenDay?.resetsAt,
        )
    }
}
