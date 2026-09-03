import Foundation

/// Incrementally foldable aggregate of one transcript file's usage records.
///
/// This is what makes byte-offset resumption possible: instead of re-parsing a
/// whole file each scan, the scanner keeps one accumulator per file and folds
/// only the newly appended records into it. `message.id` dedup happens at fold
/// time: Claude Code writes one JSONL entry per content block, all repeating the
/// same id, but the usage is NOT identical — the first entry carries the
/// streaming-partial `output_tokens` and a later one the final count — so the
/// largest reading per id wins. Two accumulators can `merged(with:)` so a parent
/// transcript and its subagent transcripts combine into one session.
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
    /// Cwd of the newest record that carried one — where the session is NOW.
    /// Sessions move (cd, `--resume` from another dir); the label and the
    /// live-process cwd match must follow, or the session stays pinned to its
    /// birth directory and never matches its process again. Hops into
    /// `.claude/worktrees/` are the exception: tools stamp those on records while
    /// the process stays put (see `ClaudeWorktree`).
    private var lastCwd: String?
    private var lastCwdStamp: Date?
    /// Best reading seen per `message.id`, so a later entry with the final
    /// `output_tokens` can replace the streaming-partial one already folded.
    private var seenMessageIDs: [String: TokenBreakdown] = [:]
    private var burnEvents: [BurnEvent] = []
    /// Model of the newest record that carried one, with its timestamp — "the
    /// model being used", unlike `models` which is the alphabetical full set.
    private var lastModel: String?
    private var lastModelStamp: Date?

    public init(burnWindow: TimeInterval = 300) {
        self.burnWindow = burnWindow
    }

    public var isEmpty: Bool { messageCount == 0 }

    /// Fold one record in. A record repeating an already-seen `message.id` only
    /// contributes the growth over the reading already folded (or nothing);
    /// records without an id (older transcripts) always count.
    public mutating func fold(_ record: AssistantUsageRecord) {
        if let id = record.messageID, let previous = seenMessageIDs[id] {
            // Field-wise, so a reading that only grew `cacheRead` (outside `total`)
            // still lands, and no field can be pulled backwards by a partial entry.
            let best = TokenBreakdown.max(previous, record.tokens)
            guard best != previous else { return }
            let delta = best - previous
            seenMessageIDs[id] = best
            tokens += delta
            if delta.total > 0 { burnEvents.append(BurnEvent(timestamp: record.timestamp, total: delta.total)) }
            return
        }
        if let id = record.messageID { seenMessageIDs[id] = record.tokens }

        tokens += record.tokens
        if let model = record.model {
            models.insert(model)
            if lastModelStamp == nil || record.timestamp >= lastModelStamp! {
                lastModel = model
                lastModelStamp = record.timestamp
            }
        }
        messageCount += 1
        firstTimestamp = min(firstTimestamp ?? record.timestamp, record.timestamp)
        lastTimestamp = max(lastTimestamp ?? record.timestamp, record.timestamp)
        if let cwd = record.cwd, lastCwdStamp == nil || record.timestamp >= lastCwdStamp!,
           !ClaudeWorktree.isHop(from: lastCwd, to: cwd) {
            lastCwd = cwd
            lastCwdStamp = record.timestamp
        }

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
    /// is what the process probe matches against, and its `lastModel` wins,
    /// because the headline model is what the main conversation runs on —
    /// subagents are routinely cheaper models whose newer records must not
    /// relabel the session. The subagent's model is only a fallback.
    public func merged(with other: SessionAccumulator) -> SessionAccumulator {
        var result = self
        result.tokens = tokens + other.tokens
        result.models = models.union(other.models)
        result.messageCount = messageCount + other.messageCount
        result.firstTimestamp = [firstTimestamp, other.firstTimestamp].compactMap(\.self).min()
        result.lastTimestamp = [lastTimestamp, other.lastTimestamp].compactMap(\.self).max()
        result.lastCwd = lastCwd ?? other.lastCwd
        result.lastCwdStamp = lastCwd != nil ? lastCwdStamp : other.lastCwdStamp
        // An id folded on both sides was counted twice: keep the field-wise larger
        // reading and take the rest back out.
        var seen = seenMessageIDs
        var duplicated = TokenBreakdown.zero
        var duplicateCount = 0
        for (id, reading) in other.seenMessageIDs {
            if let mine = seen[id] {
                let best = TokenBreakdown.max(mine, reading)
                duplicated += mine + reading - best
                duplicateCount += 1
                seen[id] = best
            } else {
                seen[id] = reading
            }
        }
        result.seenMessageIDs = seen
        result.tokens = tokens + other.tokens - duplicated
        result.messageCount = messageCount + other.messageCount - duplicateCount
        result.burnEvents = burnEvents + other.burnEvents
        if lastModel == nil {
            result.lastModel = other.lastModel
            result.lastModelStamp = other.lastModelStamp
        }
        return result
    }

    /// Snapshot the folded state as a `SessionUsage`, or nil if nothing folded.
    public func usage(
        id: String,
        projectPath: String,
        origin: SessionOrigin,
        title: String?,
        now: Date,
    ) -> SessionUsage? {
        guard messageCount > 0 else { return nil }

        let windowStart = now.addingTimeInterval(-burnWindow)
        let windowTokens = burnEvents.filter { $0.timestamp > windowStart }.reduce(0) { $0 + $1.total }
        let minutes = burnWindow / 60
        let burnRate = minutes > 0 ? Double(windowTokens) / minutes : 0

        return SessionUsage(
            id: id,
            origin: origin,
            projectPath: projectPath.isEmpty ? (lastCwd ?? "") : projectPath,
            title: title,
            models: models.sorted(),
            lastModel: lastModel,
            tokens: tokens,
            messageCount: messageCount,
            firstActivity: firstTimestamp ?? now,
            lastActivity: lastTimestamp ?? now,
            burnRate: burnRate,
        )
    }
}
