import Foundation

/// Decides which sessions are still live, from process/app liveness signals.
public struct RunningResolver: Sendable {
    private let desktopRecency: TimeInterval

    public init(desktopRecency: TimeInterval = 300) {
        self.desktopRecency = desktopRecency
    }

    /// Resolves `tool`'s sessions; sessions of any other tool are returned unchanged.
    /// `liveCwdCounts` and `desktopAppRunning` are `tool`'s own signals, so one tool's
    /// processes can never mark another tool's session in the same folder running.
    ///
    /// `activityAt` maps session id -> transcript file mtime. The file mtime is a
    /// stronger activity signal than the last assistant record (it also moves on
    /// user messages and attachments); sessions without an entry fall back to
    /// `lastActivity`.
    public func resolve(
        sessions: [SessionUsage],
        tool: AgentTool,
        liveCwdCounts: [String: Int],
        desktopAppRunning: Bool,
        activityAt: [String: Date] = [:],
        now: Date,
    ) -> [SessionUsage] {
        func activity(_ session: SessionUsage) -> Date {
            activityAt[session.id] ?? session.lastActivity
        }

        // Terminal sessions: per project path, the K newest are running (K = live
        // process count of `tool`).
        var runningCLIIDs: Set<String> = []
        let terminal = sessions.filter { $0.origin.tool == tool && $0.origin.isTerminal }
        for (path, group) in Dictionary(grouping: terminal, by: \.projectPath) {
            let k = liveCwdCounts[path] ?? 0
            guard k > 0 else { continue }
            let newest = group.sorted { activity($0) > activity($1) }.prefix(k)
            runningCLIIDs.formUnion(newest.map(\.id))
        }

        let staleCutoff = now.addingTimeInterval(-desktopRecency)
        return sessions.map { session in
            guard session.origin.tool == tool else { return session }
            if session.origin.isTerminal {
                return session.withRunning(runningCLIIDs.contains(session.id) ? .running : .idle)
            }
            let live = desktopAppRunning && activity(session) >= staleCutoff
            return session.withRunning(live ? .running : .idle)
        }
    }
}
