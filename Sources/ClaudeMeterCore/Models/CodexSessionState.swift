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
    /// Newest `rate_limits` reading in this transcript.
    public var latestLimits: CodexLimitReading?
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
        latestLimits: CodexLimitReading? = nil,
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
        self.latestLimits = latestLimits
        self.turnCount = turnCount
        self.isLegacyHistory = isLegacyHistory
        self.isImportedLegacy = isImportedLegacy
    }

    /// Real Codex work: not an untouched import, and it has used tokens or seen limits.
    /// One such session is what makes Codex "present" in the UI.
    public var isCodexWork: Bool {
        !isImportedLegacy && (tokens.total > 0 || latestLimits != nil)
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
            if let limits, limits.observedAt >= latestLimits?.observedAt ?? .distantPast {
                latestLimits = limits
            }
        case .other:
            break
        }
    }
}
