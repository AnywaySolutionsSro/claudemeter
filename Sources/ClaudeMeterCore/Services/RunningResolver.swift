import Foundation

/// Decides which sessions are still live, from process/app liveness signals.
public struct RunningResolver: Sendable {
    private let desktopRecency: TimeInterval

    public init(desktopRecency: TimeInterval = 300) {
        self.desktopRecency = desktopRecency
    }

    public func resolve(
        sessions: [SessionUsage],
        liveCwdCounts: [String: Int],
        desktopAppRunning: Bool,
        now: Date
    ) -> [SessionUsage] {
        // CLI: per project path, the K newest sessions are running (K = live process count).
        let cli = sessions.filter { $0.origin == .cli }
        var runningCLIIDs: Set<String> = []
        let groups = Dictionary(grouping: cli, by: \.projectPath)
        for (path, group) in groups {
            let k = liveCwdCounts[path] ?? 0
            guard k > 0 else { continue }
            let newest = group.sorted { $0.lastActivity > $1.lastActivity }.prefix(k)
            runningCLIIDs.formUnion(newest.map(\.id))
        }

        let staleCutoff = now.addingTimeInterval(-desktopRecency)
        return sessions.map { session in
            switch session.origin {
            case .cli:
                return session.withRunning(runningCLIIDs.contains(session.id) ? .running : .idle)
            case .desktop:
                let live = desktopAppRunning && session.lastActivity >= staleCutoff
                return session.withRunning(live ? .running : .idle)
            }
        }
    }
}
