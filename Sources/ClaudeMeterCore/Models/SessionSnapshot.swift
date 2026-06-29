import Foundation

/// Compact, serializable view of the current sessions, shared with the widget.
public struct SessionSnapshot: Equatable, Sendable, Codable {
    public let generatedAt: Date
    public let sessions: [SessionUsage]
    public let totalTokens: Int
    public let runningCount: Int
    public let armedSessionIDs: [String]
    public let armableSessionIDs: [String]

    public init(generatedAt: Date, sessions: [SessionUsage], totalTokens: Int,
                runningCount: Int, armedSessionIDs: [String] = [], armableSessionIDs: [String] = []) {
        self.generatedAt = generatedAt
        self.sessions = sessions
        self.totalTokens = totalTokens
        self.runningCount = runningCount
        self.armedSessionIDs = armedSessionIDs
        self.armableSessionIDs = armableSessionIDs
    }

    // Custom decode so snapshots written before these fields existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        sessions = try c.decode([SessionUsage].self, forKey: .sessions)
        totalTokens = try c.decode(Int.self, forKey: .totalTokens)
        runningCount = try c.decode(Int.self, forKey: .runningCount)
        armedSessionIDs = try c.decodeIfPresent([String].self, forKey: .armedSessionIDs) ?? []
        armableSessionIDs = try c.decodeIfPresent([String].self, forKey: .armableSessionIDs) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt, sessions, totalTokens, runningCount, armedSessionIDs, armableSessionIDs
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
        runningOnly: Bool = false,
        armedSessionIDs: [String] = [],
        armableSessionIDs: [String] = []
    ) -> SessionSnapshot {
        let pool = runningOnly ? sessions.filter { $0.running == .running } : sessions
        let ranked = pool.sorted { $0.totalTokens > $1.totalTokens }
        return SessionSnapshot(
            generatedAt: now,
            sessions: Array(ranked.prefix(limit)),
            totalTokens: sessions.reduce(0) { $0 + $1.totalTokens },
            runningCount: sessions.filter { $0.running == .running }.count,
            armedSessionIDs: armedSessionIDs,
            armableSessionIDs: armableSessionIDs
        )
    }
}
