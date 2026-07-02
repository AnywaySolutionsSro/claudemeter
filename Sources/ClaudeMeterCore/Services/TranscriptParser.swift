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
    public init() {}

    public func parseLine(_ line: String) -> AssistantUsageRecord? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "assistant",
              let message = root["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }

        let tokens = TokenBreakdown(
            input: int("input_tokens"),
            output: int("output_tokens"),
            cacheCreation: int("cache_creation_input_tokens"),
            cacheRead: int("cache_read_input_tokens")
        )

        let timestamp = (root["timestamp"] as? String).flatMap(ISODate.parse) ?? Date(timeIntervalSince1970: 0)
        return AssistantUsageRecord(
            timestamp: timestamp,
            model: message["model"] as? String,
            cwd: root["cwd"] as? String,
            tokens: tokens,
            messageID: message["id"] as? String
        )
    }

    public func parse(_ lines: [String]) -> ParsedTranscript {
        var records: [AssistantUsageRecord] = []
        var malformed = 0
        for line in lines {
            if let record = parseLine(line) {
                records.append(record)
                continue
            }
            // Count lines that were clearly meant to be assistant usage but failed.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = trimmed.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               root["type"] as? String == "assistant" {
                malformed += 1
            }
        }
        return ParsedTranscript(records: records, malformedLineCount: malformed)
    }
}
