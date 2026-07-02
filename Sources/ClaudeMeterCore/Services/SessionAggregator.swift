import Foundation

/// Folds the parsed records of one transcript into a single `SessionUsage`.
public struct SessionAggregator: Sendable {
    private let burnWindow: TimeInterval

    public init(burnWindow: TimeInterval = 300) {
        self.burnWindow = burnWindow
    }

    /// One-shot convenience over `SessionAccumulator` (which owns the fold logic,
    /// message.id dedup included): fold every record, snapshot the usage.
    public func aggregate(
        _ parsed: ParsedTranscript,
        id: String,
        projectPath: String,
        origin: SessionOrigin,
        title: String?,
        now: Date
    ) -> SessionUsage? {
        var accumulator = SessionAccumulator(burnWindow: burnWindow)
        for record in parsed.records {
            accumulator.fold(record)
        }
        return accumulator.usage(id: id, projectPath: projectPath, origin: origin, title: title, now: now)
    }
}
