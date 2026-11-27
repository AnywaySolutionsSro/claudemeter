import Foundation

/// Decides which sessions are still live, from process/app liveness signals.
public struct RunningResolver: Sendable {
    private let desktopRecency: TimeInterval

    public init(desktopRecency: TimeInterval = 300) {
        self.desktopRecency = desktopRecency
    }

    /// `activityAt` maps session id -> transcript file mtime. The file mtime is a
    /// stronger activity signal than the last assistant record (it also moves on
    /// user messages and attachments); sessions without an entry fall back to
    /// `lastActivity`.
    public func resolve(
        sessions: [SessionUsage],
        liveCwdCounts: [String: Int],
        desktopAppRunning: Bool,
        activityAt: [String: Date] = [:],
        now: Date,
    ) -> [SessionUsage] {
        func activity(_ session: SessionUsage) -> Date {
            activityAt[session.id] ?? session.lastActivity
        }

        // Terminal sessions: per project path, the K newest are running (K = live
        // process count). Each tool is grouped on its own; callers pass the counts
        // of that tool's processes (Claude and Codex scanners resolve separately).
        var runningCLIIDs: Set<String> = []
        for origin in [SessionOrigin.cli, .codexCLI] {
            let groups = Dictionary(grouping: sessions.filter { $0.origin == origin }, by: \.projectPath)
            for (path, group) in groups {
                let k = liveCwdCounts[path] ?? 0
                guard k > 0 else { continue }
                let newest = group.sorted { activity($0) > activity($1) }.prefix(k)
                runningCLIIDs.formUnion(newest.map(\.id))
            }
        }

        let staleCutoff = now.addingTimeInterval(-desktopRecency)
        return sessions.map { session in
            switch session.origin {
            case .cli, .codexCLI:
                return session.withRunning(runningCLIIDs.contains(session.id) ? .running : .idle)
            case .desktop, .codexDesktop:
                let live = desktopAppRunning && activity(session) >= staleCutoff
                return session.withRunning(live ? .running : .idle)
            }
        }
    }
}
