import ClaudeMeterCore
import Foundation

/// Turns consecutive limit readings of one tool into notifications.
///
/// Claude's alerts still flow through `UsageStore.onEvents`; this serves tools whose
/// limits arrive as plain snapshots (Codex). Each tool keeps its own baseline, and the
/// first reading of a run seeds it silently — a launch at already-high usage, or a
/// days-old reading, must not read as a crossing.
@MainActor
final class LimitAlertTracker {
    private let settings: Settings
    private let notifications: NotificationManager
    /// Whether Codex is on this machine, which decides if Claude's titles name the tool.
    private let codexPresent: @MainActor () -> Bool
    private var previous: [AgentTool: UsageSnapshot] = [:]

    init(settings: Settings, notifications: NotificationManager, codexPresent: @escaping @MainActor () -> Bool) {
        self.settings = settings
        self.notifications = notifications
        self.codexPresent = codexPresent
    }

    func ingest(tool: AgentTool, snapshot: UsageSnapshot, now: Date) {
        let baseline = previous[tool]
        previous[tool] = snapshot
        guard isEnabled(tool) else { return }
        for event in LimitEvents.detect(previous: baseline, current: snapshot, now: now) {
            switch event {
            case let .reset(window):
                notifications.notifyRefill(window, tool: tool, codexPresent: codexPresent())
            case let .crossed(threshold, window, eta):
                notifications.notifyThreshold(
                    threshold, window: window, etaToReset: eta, tool: tool, codexPresent: codexPresent(),
                )
            }
        }
    }

    /// Forget `tool`'s baseline, so its next reading seeds silently (a hidden tool).
    func resetBaseline(tool: AgentTool) {
        previous[tool] = nil
    }

    /// "Remind me when it resets" for a tool's window, namespaced so Claude's and
    /// Codex's reminders never replace each other.
    func scheduleResetReminder(tool: AgentTool, window: LimitWindow) {
        guard let resetAt = window.bucket.resetsAt else { return }
        notifications.scheduleResetReminder(at: resetAt, for: window, tool: tool, codexPresent: codexPresent())
    }

    private func isEnabled(_ tool: AgentTool) -> Bool {
        switch tool {
        case .claude: settings.notificationsEnabled
        case .codex: settings.codexNotificationsEnabled
        }
    }
}
