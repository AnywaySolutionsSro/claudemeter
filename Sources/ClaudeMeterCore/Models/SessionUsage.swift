import Foundation

/// Aggregated token usage for one Claude Code session (one transcript file).
public struct SessionUsage: Equatable, Sendable, Codable, Identifiable {
    public let id: String
    public let origin: SessionOrigin
    public let projectPath: String
    public let title: String?
    public let models: [String]
    /// Model of the most recent usage record — "the model being used" for display.
    /// Optional so snapshots written before this field existed still decode.
    public let lastModel: String?
    public let tokens: TokenBreakdown
    public let messageCount: Int
    public let firstActivity: Date
    public let lastActivity: Date
    public let burnRate: Double
    public var running: RunningState

    public init(
        id: String,
        origin: SessionOrigin,
        projectPath: String,
        title: String? = nil,
        models: [String],
        lastModel: String? = nil,
        tokens: TokenBreakdown,
        messageCount: Int,
        firstActivity: Date,
        lastActivity: Date,
        burnRate: Double,
        running: RunningState = .idle
    ) {
        self.id = id
        self.origin = origin
        self.projectPath = projectPath
        self.title = title
        self.models = models
        self.lastModel = lastModel
        self.tokens = tokens
        self.messageCount = messageCount
        self.firstActivity = firstActivity
        self.lastActivity = lastActivity
        self.burnRate = burnRate
        self.running = running
    }

    public var projectName: String {
        let name = (projectPath as NSString).lastPathComponent
        return name.isEmpty ? projectPath : name
    }

    public var totalTokens: Int { tokens.total }
    public var cacheReadTokens: Int { tokens.cacheRead }

    public func withRunning(_ state: RunningState) -> SessionUsage {
        var copy = self
        copy.running = state
        return copy
    }

    public func withProjectPath(_ path: String) -> SessionUsage {
        SessionUsage(id: id, origin: origin, projectPath: path, title: title, models: models,
                     lastModel: lastModel, tokens: tokens, messageCount: messageCount,
                     firstActivity: firstActivity, lastActivity: lastActivity,
                     burnRate: burnRate, running: running)
    }
}
