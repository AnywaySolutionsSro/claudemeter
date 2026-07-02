import Foundation

/// Incrementally foldable aggregate of one transcript file's usage records.
///
/// This is what makes byte-offset resumption possible: instead of re-parsing a
/// whole file each scan, the scanner keeps one accumulator per file and folds
/// only the newly appended records into it. `message.id` dedup happens at fold
/// time (Claude Code writes one JSONL entry per content block, all repeating the
/// same id and identical usage), and two accumulators can `merged(with:)` so a
/// parent transcript and its subagent transcripts combine into one session.
public struct SessionAccumulator: Equatable, Sendable {
    /// A folded record's contribution to the trailing burn-rate window.
    private struct BurnEvent: Equatable, Sendable {
        let timestamp: Date
        let total: Int
    }

    private let burnWindow: TimeInterval
    private var tokens: TokenBreakdown = .zero
    private var models: Set<String> = []
    private var messageCount = 0
    private var firstTimestamp: Date?
    private var lastTimestamp: Date?
    private var firstCwd: String?
    private var seenMessageIDs: Set<String> = []
    private var burnEvents: [BurnEvent] = []

    public init(burnWindow: TimeInterval = 300) {
        self.burnWindow = burnWindow
    }

    public var isEmpty: Bool { messageCount == 0 }

    /// Fold one record in. Records repeating an already-seen `message.id` are
    /// dropped; records without an id (older transcripts) always count.
    public mutating func fold(_ record: AssistantUsageRecord) {
        if let id = record.messageID, !seenMessageIDs.insert(id).inserted { return }

        tokens = tokens + record.tokens
        if let model = record.model { models.insert(model) }
        messageCount += 1
        firstTimestamp = min(firstTimestamp ?? record.timestamp, record.timestamp)
        lastTimestamp = max(lastTimestamp ?? record.timestamp, record.timestamp)
        if firstCwd == nil { firstCwd = record.cwd }

        burnEvents.append(BurnEvent(timestamp: record.timestamp, total: record.tokens.total))
        // Keep only events that can still fall inside a window anchored at (or
        // after) the newest activity; older ones can never matter again.
        if let last = lastTimestamp {
            let horizon = last.addingTimeInterval(-burnWindow)
            burnEvents = burnEvents.filter { $0.timestamp > horizon }
        }
    }

    /// Combine two accumulators (parent transcript + a subagent transcript).
    /// `self` is the primary: its cwd wins, because the parent transcript's cwd
    /// is what the process probe matches against.
    public func merged(with other: SessionAccumulator) -> SessionAccumulator {
        var result = self
        result.tokens = tokens + other.tokens
        result.models = models.union(other.models)
        result.messageCount = messageCount + other.messageCount
        result.firstTimestamp = [firstTimestamp, other.firstTimestamp].compactMap { $0 }.min()
        result.lastTimestamp = [lastTimestamp, other.lastTimestamp].compactMap { $0 }.max()
        result.firstCwd = firstCwd ?? other.firstCwd
        result.seenMessageIDs = seenMessageIDs.union(other.seenMessageIDs)
        result.burnEvents = burnEvents + other.burnEvents
        return result
    }

    /// Snapshot the folded state as a `SessionUsage`, or nil if nothing folded.
    public func usage(
        id: String,
        projectPath: String,
        origin: SessionOrigin,
        title: String?,
        now: Date
    ) -> SessionUsage? {
        guard messageCount > 0 else { return nil }

        let windowStart = now.addingTimeInterval(-burnWindow)
        let windowTokens = burnEvents.filter { $0.timestamp > windowStart }.reduce(0) { $0 + $1.total }
        let minutes = burnWindow / 60
        let burnRate = minutes > 0 ? Double(windowTokens) / minutes : 0

        return SessionUsage(
            id: id,
            origin: origin,
            projectPath: projectPath.isEmpty ? (firstCwd ?? "") : projectPath,
            title: title,
            models: models.sorted(),
            tokens: tokens,
            messageCount: messageCount,
            firstActivity: firstTimestamp ?? now,
            lastActivity: lastTimestamp ?? now,
            burnRate: burnRate
        )
    }
}
