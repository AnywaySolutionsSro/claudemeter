import Foundation

/// Everything ClaudeMeter knows about one Codex session (one `rollout-*.jsonl`),
/// built by folding its lines in order. Incremental: fold the lines appended since
/// the last scan onto the previous state. Pure — `folding` returns a new value.
public struct CodexSessionState: Sendable, Equatable {
    public var id: String?
    public var cwd: String?
    /// `codex-tui` (terminal) or `Codex Desktop`.
    public var originator: String?
    /// Model of the most recent turn.
    public var model: String?
    /// Every model seen, in first-use order.
    public var models: [String]
    /// The session's cumulative usage from its **latest** `token_count` (not a sum).
    public var tokens: TokenBreakdown
    public var firstActivity: Date?
    public var lastActivity: Date?
    /// Newest `rate_limits` reading in this transcript **per `limit_id`**: a later
    /// reading under another id must not replace the "codex" one.
    public var latestLimitsByID: [String: CodexLimitReading]
    /// Past `rate_limits` readings per `limit_id`, oldest first, thinned to the newest
    /// one per minute and capped, to seed Codex's history (`CodexHistory.backfilled`).
    public var limitHistoryByID: [String: [CodexLimitReading]]
    /// Turns started (`task_started` events).
    public var turnCount: Int
    /// `session_meta.history_mode == "legacy"`.
    public var isLegacyHistory: Bool
    /// A Claude Code thread Codex Desktop imported (legacy history, listed in
    /// `external_agent_session_imports.json`) that has not accrued Codex tokens.
    /// Already counted as Claude, so it is neither listed nor makes Codex "present".
    public var isImportedLegacy: Bool

    public init(
        id: String? = nil,
        cwd: String? = nil,
        originator: String? = nil,
        model: String? = nil,
        models: [String] = [],
        tokens: TokenBreakdown = .zero,
        firstActivity: Date? = nil,
        lastActivity: Date? = nil,
        latestLimitsByID: [String: CodexLimitReading] = [:],
        limitHistoryByID: [String: [CodexLimitReading]] = [:],
        turnCount: Int = 0,
        isLegacyHistory: Bool = false,
        isImportedLegacy: Bool = false,
    ) {
        self.id = id
        self.cwd = cwd
        self.originator = originator
        self.model = model
        self.models = models
        self.tokens = tokens
        self.firstActivity = firstActivity
        self.lastActivity = lastActivity
        self.latestLimitsByID = latestLimitsByID
        self.limitHistoryByID = limitHistoryByID
        self.turnCount = turnCount
        self.isLegacyHistory = isLegacyHistory
        self.isImportedLegacy = isImportedLegacy
    }

    /// The reading to show for this transcript: the newest "codex" one, else the newest of any id.
    public var latestLimits: CodexLimitReading? {
        CodexLimits.newest(Array(latestLimitsByID.values))
    }

    /// Real Codex work: not an untouched import, and it has used tokens or seen limits.
    /// One such session is what makes Codex "present" in the UI.
    public var isCodexWork: Bool {
        !isImportedLegacy && (tokens.total > 0 || !latestLimitsByID.isEmpty)
    }

    /// This state with `lines` applied. Malformed lines are skipped. `importedIDs`
    /// are the thread ids from Codex's imports file (see `isImportedLegacy`).
    public func folding(_ lines: [String], importedIDs: Set<String> = []) -> CodexSessionState {
        lines.compactMap(CodexTranscriptParser.parse).reduce(into: self) { state, line in
            state.apply(line, importedIDs: importedIDs)
        }
    }

    private mutating func apply(_ line: CodexTranscriptLine, importedIDs: Set<String>) {
        if let timestamp = line.timestamp {
            firstActivity = min(firstActivity ?? timestamp, timestamp)
            lastActivity = max(lastActivity ?? timestamp, timestamp)
        }
        switch line.event {
        case let .meta(id, cwd, originator, historyMode):
            self.id = id ?? self.id
            self.cwd = cwd ?? self.cwd
            self.originator = originator ?? self.originator
            isLegacyHistory = historyMode == "legacy"
            isImportedLegacy = isLegacyHistory && id.map(importedIDs.contains) == true && tokens.total == 0
        case let .model(name):
            model = name
            if !models.contains(name) { models.append(name) }
        case .turnStarted:
            turnCount += 1
        case let .tokenCount(newTokens, limits):
            if let newTokens {
                tokens = newTokens
                if newTokens.total > 0 { isImportedLegacy = false }
            }
            if let limits {
                if limits.observedAt >= latestLimitsByID[limits.limitID]?.observedAt ?? .distantPast {
                    latestLimitsByID[limits.limitID] = limits
                }
                limitHistoryByID[limits.limitID] = Self.keeping(limits, in: limitHistoryByID[limits.limitID] ?? [])
            }
        case .other:
            break
        }
    }

    /// At most this many past readings per `limit_id`: a day of one-a-minute turns.
    static let maxLimitHistory = 1440

    /// `history` with `reading` kept: a reading in the same clock minute as the last
    /// kept one replaces it (a turn writes one every few seconds), and the oldest go
    /// beyond `maxLimitHistory`.
    static func keeping(_ reading: CodexLimitReading, in history: [CodexLimitReading]) -> [CodexLimitReading] {
        let minute = { (date: Date) in (date.timeIntervalSince1970 / 60).rounded(.down) }
        let base = history.last.map { minute($0.observedAt) == minute(reading.observedAt) } == true
            ? Array(history.dropLast()) : history
        return Array((base + [reading]).suffix(maxLimitHistory))
    }
}
