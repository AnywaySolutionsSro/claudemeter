import Foundation

/// A point-in-time view of all rate-limit windows returned by the usage API.
public struct UsageSnapshot: Equatable, Sendable {
    public let fiveHour: UsageBucket?
    public let sevenDay: UsageBucket?
    public let sevenDayOpus: UsageBucket?
    public let sevenDaySonnet: UsageBucket?
    public let fetchedAt: Date

    public init(
        fiveHour: UsageBucket?,
        sevenDay: UsageBucket?,
        sevenDayOpus: UsageBucket?,
        sevenDaySonnet: UsageBucket?,
        fetchedAt: Date
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.fetchedAt = fetchedAt
    }

    /// The window shown in the menu bar by default: the frequently-resetting 5-hour
    /// session limit, falling back to the weekly window if the session bucket is absent.
    public var primary: UsageBucket? { fiveHour ?? sevenDay }

    /// All present buckets, useful for the dropdown detail view.
    public var allBuckets: [(title: String, bucket: UsageBucket)] {
        var rows: [(String, UsageBucket)] = []
        if let b = fiveHour { rows.append(("Session (5h)", b)) }
        if let b = sevenDay { rows.append(("Weekly", b)) }
        if let b = sevenDayOpus { rows.append(("Weekly · Opus", b)) }
        if let b = sevenDaySonnet { rows.append(("Weekly · Sonnet", b)) }
        return rows
    }

    /// The window closest to its limit — the binding constraint right now.
    public var mostConstrained: UsageBucket? {
        [fiveHour, sevenDay, sevenDayOpus, sevenDaySonnet]
            .compactMap { $0 }
            .max { $0.utilization < $1.utilization }
    }
}
