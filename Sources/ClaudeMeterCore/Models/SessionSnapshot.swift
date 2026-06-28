import Foundation

/// Compact, serializable view of the current sessions, shared with the widget.
public struct SessionSnapshot: Equatable, Sendable, Codable {
    public let generatedAt: Date
    public let sessions: [SessionUsage]
    public let totalTokens: Int
    public let runningCount: Int

    public init(generatedAt: Date, sessions: [SessionUsage], totalTokens: Int, runningCount: Int) {
        self.generatedAt = generatedAt
        self.sessions = sessions
        self.totalTokens = totalTokens
        self.runningCount = runningCount
    }

    /// Build a snapshot of the top sessions by total tokens.
    ///
    /// - Parameter runningOnly: when `true`, the kept `sessions` are limited to
    ///   currently-running ones (used by the widget). `totalTokens` and
    ///   `runningCount` are always computed across *all* input sessions.
    public static func make(
        from sessions: [SessionUsage],
        now: Date,
        limit: Int = 5,
        runningOnly: Bool = false
    ) -> SessionSnapshot {
        let pool = runningOnly ? sessions.filter { $0.running == .running } : sessions
        let ranked = pool.sorted { $0.totalTokens > $1.totalTokens }
        return SessionSnapshot(
            generatedAt: now,
            sessions: Array(ranked.prefix(limit)),
            totalTokens: sessions.reduce(0) { $0 + $1.totalTokens },
            runningCount: sessions.filter { $0.running == .running }.count
        )
    }
}
