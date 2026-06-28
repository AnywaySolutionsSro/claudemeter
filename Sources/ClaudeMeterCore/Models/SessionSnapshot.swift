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

    public static func make(from sessions: [SessionUsage], now: Date, limit: Int = 5) -> SessionSnapshot {
        let ranked = sessions.sorted { $0.totalTokens > $1.totalTokens }
        return SessionSnapshot(
            generatedAt: now,
            sessions: Array(ranked.prefix(limit)),
            totalTokens: sessions.reduce(0) { $0 + $1.totalTokens },
            runningCount: sessions.filter { $0.running == .running }.count
        )
    }
}
