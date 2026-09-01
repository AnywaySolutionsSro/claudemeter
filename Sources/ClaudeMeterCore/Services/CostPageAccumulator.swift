import Foundation

/// Folds the pages of a paginated cost report into one set of days.
///
/// Lives in core (rather than inline in the networking client) so the money-critical rules
/// — deduplication, cursor-loop detection, and the page budget — are unit-testable.
///
/// Every failure here is deliberately loud. An understated total presented as complete is
/// worse than no total at all, because the user cannot tell it is wrong.
public struct CostPageAccumulator {
    /// A ~62-day window at the API's 31-bucket cap needs 3 pages; 4 is headroom.
    public static let maxPages = 4

    public enum Failure: Error, Equatable, LocalizedError {
        case repeatedCursor
        case tooManyPages

        public var errorDescription: String? {
            switch self {
            case .repeatedCursor, .tooManyPages:
                "Couldn't read the whole cost report — showing the last complete reading."
            }
        }
    }

    public private(set) var days: [CostDay] = []
    public private(set) var skippedRows = 0
    public private(set) var skippedBuckets = 0

    private var seenCursors: Set<String> = []
    private var pageCount = 0
    private var seenStarts: Set<Date> = []

    public init() {}

    /// Anything the decoder could not read means the total is understated.
    public var isDegraded: Bool { skippedRows > 0 || skippedBuckets > 0 }

    /// Folds one page in and returns the cursor to request next, or `nil` when complete.
    public mutating func accept(_ page: CostReportDecoder.Page) throws -> String? {
        pageCount += 1
        skippedRows += page.skippedRows
        skippedBuckets += page.skippedBuckets

        for day in page.days where seenStarts.insert(day.start).inserted {
            days.append(day)
        }

        guard let next = page.nextPage else { return nil }
        guard pageCount < Self.maxPages else { throw Failure.tooManyPages }
        guard seenCursors.insert(next).inserted else { throw Failure.repeatedCursor }
        return next
    }

    public func snapshot(fetchedAt: Date) -> ApiSpendSnapshot {
        ApiSpendSnapshot(days: days.sorted { $0.start < $1.start }, fetchedAt: fetchedAt)
    }
}
