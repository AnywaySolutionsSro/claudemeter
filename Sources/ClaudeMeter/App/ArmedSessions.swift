import ClaudeMeterCore
import Combine
import Foundation

/// The set of armed session UUIDs, persisted to Application Support and mirrored
/// from widget-issued disarm commands. The single source of truth in the app.
@MainActor
final class ArmedSessions: ObservableObject {
    @Published private(set) var armed: Set<String> = []

    private let store = ArmedSessionsStore()
    private let armedURL: URL
    private let commandURL: URL
    private let pruner = ArmedSessionPruner()
    /// Consecutive not-running scan counts per armed session (pruning state).
    private var pruneMisses: [String: Int] = [:]

    init(armedURL: URL = ArmedSessions.defaultArmedURL(),
         commandURL: URL = ArmedSessions.commandInboxURL())
    {
        self.armedURL = armedURL
        self.commandURL = commandURL
        self.armed = store.read(from: armedURL)
    }

    var count: Int { armed.count }
    func isArmed(_ id: String) -> Bool { armed.contains(id) }

    func setArmed(_ id: String, _ value: Bool) {
        if value { armed.insert(id) } else { armed.remove(id) }
        persist()
    }

    func disarm(_ id: String) { setArmed(id, false) }

    func disarmAll() {
        guard !armed.isEmpty else { return }
        armed.removeAll()
        persist()
    }

    /// Apply any arm/disarm requests the widget queued, returning whether anything
    /// changed. Arm requests are honored only for sessions that are still armable
    /// (iTerm2 + running) per `isArmable`, re-validated here so a stale widget
    /// cannot arm an unsupported session.
    @discardableResult
    func drainWidgetCommands(isArmable: (String) -> Bool) -> Bool {
        let commands = store.drainCommands(at: commandURL)
        guard !commands.isEmpty else { return false }
        var changed = false
        for command in commands {
            switch command.action {
            case .disarm:
                if armed.remove(command.sessionID) != nil { changed = true }
            case .arm:
                if isArmable(command.sessionID), armed.insert(command.sessionID).inserted { changed = true }
            }
        }
        if changed { persist() }
        return changed
    }

    /// Auto-disarm armed sessions that stopped running (tab closed, /clear made a
    /// new session id). Call once per scan; disarm happens only after several
    /// consecutive not-running scans (see `ArmedSessionPruner`). Returns the ids
    /// disarmed this pass so the caller can log/notify.
    @discardableResult
    func pruneDead(runningIDs: Set<String>) -> Set<String> {
        let plan = pruner.plan(armed: armed, runningIDs: runningIDs, previousMisses: pruneMisses)
        pruneMisses = plan.misses
        guard !plan.disarm.isEmpty else { return [] }
        armed.subtract(plan.disarm)
        persist()
        return plan.disarm
    }

    private func persist() { try? store.write(armed, to: armedURL) }

    // MARK: URLs

    nonisolated static func defaultArmedURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeMeter", isDirectory: true)
            .appendingPathComponent("armed-sessions.json")
    }

    /// The widget writes disarm requests into its own container; the app reads them here.
    nonisolated static func commandInboxURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(SessionMonitor.widgetBundleID)/Data/Documents",
                                    isDirectory: true)
            .appendingPathComponent("widget-commands.json")
    }
}
