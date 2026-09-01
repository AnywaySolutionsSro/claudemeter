import Foundation

/// Decodes `GET /v1/organizations/cost_report` into `CostDay` values.
///
/// Lenient key-by-key parsing (like `UsageResponseDecoder`): unknown keys are ignored and
/// unparseable rows are skipped rather than failing the whole fetch.
///
/// **The `amount` field is a decimal string in CENTS, not dollars.** `"103.1554"` is $1.03.
/// Reading it as dollars overstates spend 100x. The division lives here and nowhere else.
public struct CostReportDecoder: Sendable {
    public init() {}

    public enum DecodingError: Error, Equatable { case malformed }

    /// One page of the paginated report.
    public struct Page: Equatable, Sendable {
        public let days: [CostDay]
        /// Cursor for the next page, or `nil` when `has_more` is false.
        public let nextPage: String?
        /// Rows whose `amount` could not be parsed. Non-zero means the total is understated.
        public let skippedRows: Int
        /// Buckets whose `starting_at` could not be parsed.
        public let skippedBuckets: Int

        public init(days: [CostDay], nextPage: String?, skippedRows: Int = 0,
                    skippedBuckets: Int = 0) {
            self.days = days
            self.nextPage = nextPage
            self.skippedRows = skippedRows
            self.skippedBuckets = skippedBuckets
        }
    }

    private static let centsPerDollar = Decimal(100)

    public func decode(_ data: Data) throws -> Page {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.malformed
        }

        let buckets = root["data"] as? [[String: Any]] ?? []
        var days: [CostDay] = []
        var skippedRows = 0
        var skippedBuckets = 0
        for bucket in buckets {
            guard let parsed = day(from: bucket) else {
                skippedBuckets += 1
                continue
            }
            days.append(parsed.day)
            skippedRows += parsed.skippedRows
        }

        let hasMore = (root["has_more"] as? NSNumber)?.boolValue ?? false
        let nextPage = hasMore ? root["next_page"] as? String : nil

        return Page(days: days, nextPage: nextPage,
                    skippedRows: skippedRows, skippedBuckets: skippedBuckets)
    }

    private func day(from bucket: [String: Any]) -> (day: CostDay, skippedRows: Int)? {
        guard
            let startString = bucket["starting_at"] as? String,
            let start = ISODate.parse(startString)
        else {
            return nil
        }

        // Input and output arrive as separate rows for the same model; fold them together.
        var totals: [String: Decimal] = [:]
        var order: [String] = []
        var skippedRows = 0
        for row in bucket["results"] as? [[String: Any]] ?? [] {
            guard let cents = CostAmount.parse(row["amount"]) else {
                skippedRows += 1
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

        return (
            CostDay(
                start: start,
                amountUSD: byModel.reduce(0) { $0 + $1.amountUSD },
                byModel: byModel,
            ),
            skippedRows,
        )
    }
}
