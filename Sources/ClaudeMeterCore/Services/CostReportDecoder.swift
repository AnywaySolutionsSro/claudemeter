import Foundation

/// Decodes `GET /v1/organizations/cost_report` into `CostDay` values.
///
/// Lenient key-by-key parsing (like `UsageResponseDecoder`): unknown keys are ignored and
/// unparseable rows are skipped rather than failing the whole fetch.
///
/// **The `amount` field is a decimal string in CENTS, not dollars.** `"103.1554"` is $1.03.
/// Reading it as dollars overstates spend 100x. The division lives here and nowhere else.
public struct CostReportDecoder {
    public init() {}

    public enum DecodingError: Error, Equatable { case malformed }

    /// One page of the paginated report.
    public struct Page: Equatable, Sendable {
        public let days: [CostDay]
        /// Cursor for the next page, or `nil` when `has_more` is false.
        public let nextPage: String?
    }

    private static let centsPerDollar = Decimal(100)

    public func decode(_ data: Data) throws -> Page {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.malformed
        }

        let buckets = root["data"] as? [[String: Any]] ?? []
        let days = buckets.compactMap(day(from:))

        let hasMore = (root["has_more"] as? NSNumber)?.boolValue ?? false
        let nextPage = hasMore ? root["next_page"] as? String : nil

        return Page(days: days, nextPage: nextPage)
    }

    private func day(from bucket: [String: Any]) -> CostDay? {
        guard
            let startString = bucket["starting_at"] as? String,
            let start = ISODate.parse(startString)
        else {
            return nil
        }

        // Input and output arrive as separate rows for the same model; fold them together.
        var totals: [String: Decimal] = [:]
        var order: [String] = []
        for row in bucket["results"] as? [[String: Any]] ?? [] {
            guard
                let amountString = row["amount"] as? String,
                let cents = Decimal(string: amountString)
            else {
                continue
            }
            // Rows without a model (e.g. "Code Execution Usage") still count toward the day.
            let label = row["model"] as? String ?? row["description"] as? String ?? "Other"
            if totals[label] == nil { order.append(label) }
            totals[label, default: 0] += cents / Self.centsPerDollar
        }

        let byModel = order
            .map { ModelSpend(model: $0, amountUSD: totals[$0] ?? 0) }
            .sorted(by: ApiSpendSnapshot.mostExpensiveFirst)

        return CostDay(
            start: start,
            amountUSD: byModel.reduce(0) { $0 + $1.amountUSD },
            byModel: byModel,
        )
    }
}
