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

    /// Spend so far in the UTC month containing `now`.
    ///
    /// Filtered rather than a plain total: on the first of a month the fetched window
    /// deliberately reaches back into the previous month (see `CostWindow`), and those days
    /// must not count toward this month.
    public func monthToDateUSD(now: Date) -> Decimal? {
        days.isEmpty ? nil : days(inMonthOf: now).reduce(0) { $0 + $1.amountUSD }
    }

    /// Spend in the UTC month before the one containing `now`.
    public func previousMonthUSD(now: Date) -> Decimal? {
        let calendar = CostWindow.utcCalendar
        guard
            let startOfMonth = calendar.date(
                from: calendar.dateComponents([.year, .month], from: now),
            ),
            let inPreviousMonth = calendar.date(byAdding: .month, value: -1, to: startOfMonth)
        else {
            return nil
        }
        return days.isEmpty ? nil : days(inMonthOf: inPreviousMonth).reduce(0) { $0 + $1.amountUSD }
    }

    /// The most recent **completed** day. The Cost API never reports the current day, so this
    /// — not "today" — is the freshest figure that exists.
    public var latestDay: CostDay? {
        days.max { $0.start < $1.start }
    }

    /// Optional on purpose: `?? 0` would turn "no data" into "zero dollars".
    public var latestDayUSD: Decimal? { latestDay?.amountUSD }

    /// How old this reading is. The Cost API trails real usage, and a cached snapshot can
    /// be arbitrarily old, so every surface that shows a figure must be able to say when.
    public func age(now: Date) -> TimeInterval { now.timeIntervalSince(fetchedAt) }

    /// A reading older than a day is stale enough that presenting it as current misleads.
    public func isStale(now: Date) -> Bool { age(now: now) > 24 * 60 * 60 }

    /// True when the snapshot predates the UTC month being asked about, so a
    /// "this month" figure computed from it would be a confident zero.
    public func predatesMonth(of now: Date) -> Bool {
        let calendar = CostWindow.utcCalendar
        let asked = calendar.dateComponents([.year, .month], from: now)
        return calendar.dateComponents([.year, .month], from: fetchedAt) != asked
    }

    public var isEmpty: Bool { days.isEmpty }

    /// Per-model totals for the UTC month containing `now`, most expensive first.
    public func byModel(now: Date) -> [ModelSpend] {
        var totals: [String: Decimal] = [:]
        for day in days(inMonthOf: now) {
            for entry in day.byModel {
                totals[entry.model, default: 0] += entry.amountUSD
            }
        }
        return totals
            .map { ModelSpend(model: $0.key, amountUSD: $0.value) }
            .sorted(by: Self.mostExpensiveFirst)
    }

    private func days(inMonthOf now: Date) -> [CostDay] {
        let calendar = CostWindow.utcCalendar
        let month = calendar.dateComponents([.year, .month], from: now)
        return days.filter {
            calendar.dateComponents([.year, .month], from: $0.start) == month
        }
    }

    /// Descending by amount, then alphabetical so equal amounts have a stable order.
    static func mostExpensiveFirst(_ lhs: ModelSpend, _ rhs: ModelSpend) -> Bool {
        lhs.amountUSD == rhs.amountUSD ? lhs.model < rhs.model : lhs.amountUSD > rhs.amountUSD
    }
}
