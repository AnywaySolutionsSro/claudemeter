import Foundation

/// A single timestamped reading, persisted to build history for burn-rate, sparklines,
/// averages, and reset/threshold detection.
public struct UsageSample: Codable, Equatable, Sendable {
    public let timestamp: Date
    /// Percent used (0–100) of the 5-hour session window.
    public let sessionUtilization: Double
    /// When the current session window resets — used to tell windows apart.
    public let sessionResetsAt: Date?
    /// Percent used of the weekly window, if present.
    public let weeklyUtilization: Double?

    public init(
        timestamp: Date,
        sessionUtilization: Double,
        sessionResetsAt: Date?,
        weeklyUtilization: Double?,
    ) {
        self.timestamp = timestamp
        self.sessionUtilization = sessionUtilization
        self.sessionResetsAt = sessionResetsAt
        self.weeklyUtilization = weeklyUtilization
    }
}

public extension UsageSnapshot {
    /// Capture the parts of a snapshot worth keeping in history.
    func sample(at timestamp: Date) -> UsageSample? {
        guard let session = fiveHour else { return nil }
        return UsageSample(
            timestamp: timestamp,
            sessionUtilization: session.utilization,
            sessionResetsAt: session.resetsAt,
            weeklyUtilization: sevenDay?.utilization,
        )
    }
}
