import Foundation

/// Spend attributed to one model within a day (or aggregated across days).
public struct ModelSpend: Codable, Equatable, Sendable {
    public let model: String
    public let amountUSD: Decimal

    public init(model: String, amountUSD: Decimal) {
        self.model = model
        self.amountUSD = amountUSD
    }
}

/// One UTC-aligned day of API spend.
///
/// `start` is the bucket's `starting_at`. Buckets are UTC-aligned, so a local day straddles
/// two of them; we present UTC days deliberately, so the figures agree with the invoice.
public struct CostDay: Codable, Equatable, Sendable {
    public let start: Date
    public let amountUSD: Decimal
    public let byModel: [ModelSpend]

    public init(start: Date, amountUSD: Decimal, byModel: [ModelSpend]) {
        self.start = start
        self.amountUSD = amountUSD
        self.byModel = byModel
    }
}

/// A window of API spend, as fetched from the Cost API. `Codable` so the app can hand it
/// to the widget extension as JSON.
public struct ApiSpendSnapshot: Codable, Equatable, Sendable {
    public let days: [CostDay]
    public let fetchedAt: Date

    public init(days: [CostDay], fetchedAt: Date) {
        self.days = days
        self.fetchedAt = fetchedAt
    }

    /// Total across the whole fetched window. The store requests exactly month-to-date,
    /// so this is what the UI labels "Month to date".
    public var totalUSD: Decimal { days.reduce(0) { $0 + $1.amountUSD } }

    public var isEmpty: Bool { totalUSD == 0 }

    /// Spend in the UTC day containing `now`; zero when that bucket hasn't appeared yet.
    public func todayUSD(now: Date) -> Decimal {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return days
            .first { calendar.isDate($0.start, inSameDayAs: now) }?
            .amountUSD ?? 0
    }

    /// Per-model totals across every day, most expensive first.
    public var byModel: [ModelSpend] {
        var totals: [String: Decimal] = [:]
        for day in days {
            for entry in day.byModel {
                totals[entry.model, default: 0] += entry.amountUSD
            }
        }
        return totals
            .map { ModelSpend(model: $0.key, amountUSD: $0.value) }
            .sorted(by: Self.mostExpensiveFirst)
    }

    /// Descending by amount, then alphabetical so equal amounts have a stable order.
    static func mostExpensiveFirst(_ lhs: ModelSpend, _ rhs: ModelSpend) -> Bool {
        lhs.amountUSD == rhs.amountUSD ? lhs.model < rhs.model : lhs.amountUSD > rhs.amountUSD
    }
}
