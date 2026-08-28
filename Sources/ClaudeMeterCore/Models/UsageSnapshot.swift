import Foundation

/// A point-in-time view of all rate-limit windows returned by the usage API.
public struct UsageSnapshot: Equatable, Sendable {
    public let fiveHour: UsageBucket?
    public let sevenDay: UsageBucket?
    public let sevenDayOpus: UsageBucket?
    public let sevenDaySonnet: UsageBucket?
    /// Per-model weekly windows from `limits[]` (e.g. "Fable"), in server order.
    public let modelWeekly: [ModelWeeklyLimit]
    public let fetchedAt: Date

    public init(
        fiveHour: UsageBucket?,
        sevenDay: UsageBucket?,
        sevenDayOpus: UsageBucket?,
        sevenDaySonnet: UsageBucket?,
        modelWeekly: [ModelWeeklyLimit] = [],
        fetchedAt: Date,
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.modelWeekly = modelWeekly
        self.fetchedAt = fetchedAt
    }

    /// The legacy `seven_day_opus` / `seven_day_sonnet` buckets, unless `limits[]`
    /// already carries a window for that model (then the scoped entry wins, so the
    /// same model never shows twice). Matched by substring, because the scoped
    /// label is server-controlled ("Opus", "Claude Opus", "Opus · Cowork" …).
    var legacyModelWeekly: [ModelWeeklyLimit] {
        let scoped = modelWeekly.map { $0.label.lowercased() }
        func isScoped(_ model: String) -> Bool { scoped.contains { $0.contains(model) } }
        var rows: [ModelWeeklyLimit] = []
        if let b = sevenDayOpus, !isScoped("opus") {
            rows.append(ModelWeeklyLimit(label: "Opus", bucket: b, isActive: false))
        }
        if let b = sevenDaySonnet, !isScoped("sonnet") {
            rows.append(ModelWeeklyLimit(label: "Sonnet", bucket: b, isActive: false))
        }
        return rows
    }

    /// Every per-model weekly window to display: scoped ones first, then legacy.
    /// Labels are unique (first occurrence wins) because they double as the
    /// SwiftUI identity of dropdown rows and widget gauges.
    public var allModelWeekly: [ModelWeeklyLimit] {
        var seen = Set<String>()
        return (modelWeekly + legacyModelWeekly).filter { seen.insert($0.label.lowercased()).inserted }
    }

    /// The window shown in the menu bar by default: the frequently-resetting 5-hour
    /// session limit, falling back to the weekly window if the session bucket is absent.
    public var primary: UsageBucket? { fiveHour ?? sevenDay }

    /// All present buckets, in display order, for the dropdown detail view.
    public var allBuckets: [UsageWindowRow] {
        var rows: [UsageWindowRow] = []
        if let b = fiveHour { rows.append(UsageWindowRow(title: "Session (5h)", bucket: b)) }
        if let b = sevenDay { rows.append(UsageWindowRow(title: "Weekly", bucket: b)) }
        for limit in allModelWeekly {
            rows.append(UsageWindowRow(
                title: "Weekly · \(limit.label)", bucket: limit.bucket, isActive: limit.isActive,
            ))
        }
        return rows
    }

    /// The window closest to its limit — the binding constraint right now.
    public var mostConstrained: UsageBucket? {
        ([fiveHour, sevenDay].compactMap(\.self) + allModelWeekly.map(\.bucket))
            .max { $0.utilization < $1.utilization }
    }
}
