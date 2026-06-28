import Foundation

/// Folds the parsed records of one transcript into a single `SessionUsage`.
public struct SessionAggregator: Sendable {
    private let burnWindow: TimeInterval

    public init(burnWindow: TimeInterval = 300) {
        self.burnWindow = burnWindow
    }

    public func aggregate(
        _ parsed: ParsedTranscript,
        id: String,
        projectPath: String,
        origin: SessionOrigin,
        title: String?,
        now: Date
    ) -> SessionUsage? {
        let records = parsed.records
        guard !records.isEmpty else { return nil }

        let tokens = records.reduce(TokenBreakdown.zero) { $0 + $1.tokens }
        let models = Set(records.compactMap(\.model)).sorted()
        let timestamps = records.map(\.timestamp)
        let first = timestamps.min() ?? now
        let last = timestamps.max() ?? now

        let resolvedPath = projectPath.isEmpty ? (records.first?.cwd ?? "") : projectPath

        let windowStart = now.addingTimeInterval(-burnWindow)
        let windowTokens = records
            .filter { $0.timestamp > windowStart }
            .reduce(0) { $0 + $1.tokens.total }
        let minutes = burnWindow / 60
        let burnRate = minutes > 0 ? Double(windowTokens) / minutes : 0

        return SessionUsage(
            id: id,
            origin: origin,
            projectPath: resolvedPath,
            title: title,
            models: models,
            tokens: tokens,
            messageCount: records.count,
            firstActivity: first,
            lastActivity: last,
            burnRate: burnRate
        )
    }
}
