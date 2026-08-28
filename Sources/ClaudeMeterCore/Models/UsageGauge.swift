import Foundation

/// A compact, serializable account-usage window for the widget's circular gauges.
/// One per rate-limit bucket present in a `UsageSnapshot` (Session / Weekly / …).
public struct UsageGauge: Codable, Equatable, Sendable, Identifiable {
    /// Short display label, e.g. "Session", "Weekly", "Opus", "Sonnet".
    public let label: String
    /// Percentage of the window still available (0...100) — the "left" number.
    public let percentLeft: Double
    /// When the window rolls over, or `nil` if the API didn't supply it.
    public let resetsAt: Date?

    public init(label: String, percentLeft: Double, resetsAt: Date?) {
        self.label = label
        self.percentLeft = max(0, min(100, percentLeft))
        self.resetsAt = resetsAt
    }

    public var id: String { label }
}

public extension UsageSnapshot {
    /// The account-usage windows as gauges, in display order, with short labels.
    /// Only buckets the API actually returned are included.
    var gauges: [UsageGauge] {
        var result: [UsageGauge] = []
        if let b = fiveHour { result.append(UsageGauge(
            label: "Session",
            percentLeft: b.percentRemaining,
            resetsAt: b.resetsAt,
        )) }
        if let b = sevenDay { result.append(UsageGauge(
            label: "Weekly",
            percentLeft: b.percentRemaining,
            resetsAt: b.resetsAt,
        )) }
        for limit in allModelWeekly {
            result.append(UsageGauge(
                label: limit.label,
                percentLeft: limit.bucket.percentRemaining,
                resetsAt: limit.bucket.resetsAt,
            ))
        }
        return result
    }
}
