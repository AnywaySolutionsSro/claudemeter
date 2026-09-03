import Foundation

/// One assistant message's usage, extracted from a transcript line.
public struct AssistantUsageRecord: Equatable, Sendable {
    public let timestamp: Date
    public let model: String?
    public let cwd: String?
    public let tokens: TokenBreakdown
    /// The API message id (`message.id`). Claude Code writes one JSONL entry per
    /// content block, each repeating the same id and identical usage — the
    /// aggregator uses this to count each API message exactly once.
    public let messageID: String?

    public init(timestamp: Date, model: String?, cwd: String?, tokens: TokenBreakdown,
                messageID: String? = nil) {
        self.timestamp = timestamp
        self.model = model
        self.cwd = cwd
        self.tokens = tokens
        self.messageID = messageID
    }
}

/// Result of parsing a whole transcript file.
public struct ParsedTranscript: Equatable, Sendable {
    public let records: [AssistantUsageRecord]
    public let malformedLineCount: Int

    public init(records: [AssistantUsageRecord], malformedLineCount: Int) {
        self.records = records
        self.malformedLineCount = malformedLineCount
    }
}

/// Lenient JSONL transcript parser. Never throws: malformed lines are skipped
/// (and, when they were clearly meant to be assistant usage, counted).
public struct TranscriptParser: Sendable {
    /// Upper bound for one token field. No single message approaches it; anything
    /// above is a corrupt line, not a reading.
    public static let maxTokenField = Int(Int32.max)

    public init() {}

    /// What one assistant line turned out to be, from a single JSON parse.
    private enum LineOutcome {
        case record(AssistantUsageRecord)
        /// Assistant line that should have carried usage but didn't decode.
        case malformed
        /// Deliberately not usage (non-assistant, blank, or a `<synthetic>` placeholder).
        case skipped
    }

    public func parseLine(_ line: String) -> AssistantUsageRecord? {
        if case let .record(record) = classify(line) { return record }
        return nil
    }

    public func parse(_ lines: [String]) -> ParsedTranscript {
        var records: [AssistantUsageRecord] = []
        var malformed = 0
        for line in lines {
            switch classify(line) {
            case let .record(record): records.append(record)
            case .malformed: malformed += 1
            case .skipped: break
            }
        }
        return ParsedTranscript(records: records, malformedLineCount: malformed)
    }

    private func classify(_ line: String) -> LineOutcome {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "assistant"
        else { return .skipped }

        let message = root["message"] as? [String: Any]
        // `<synthetic>` entries are error placeholders (usage-limit cutoffs etc.),
        // not real API usage: never a record, never malformed.
        if message?["model"] as? String == "<synthetic>" { return .skipped }
        guard let message, let usage = message["usage"] as? [String: Any] else {
            return .malformed
        }

        // Clamp rather than trust: a field near `Int.max` would make the
        // aggregate's addition trap, crashing the app on every launch.
        func int(_ key: String) -> Int {
            let value = (usage[key] as? NSNumber)?.int64Value ?? 0
            return Int(min(max(value, 0), Int64(Self.maxTokenField)))
        }

        let tokens = TokenBreakdown(
            input: int("input_tokens"),
            output: int("output_tokens"),
            cacheCreation: int("cache_creation_input_tokens"),
            cacheRead: int("cache_read_input_tokens"),
        )

        let timestamp = (root["timestamp"] as? String).flatMap(ISODate.parse) ?? Date(timeIntervalSince1970: 0)
        return .record(AssistantUsageRecord(
            timestamp: timestamp,
            model: message["model"] as? String,
            cwd: root["cwd"] as? String,
            tokens: tokens,
            messageID: message["id"] as? String,
        ))
    }
}
