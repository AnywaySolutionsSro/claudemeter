import Foundation

/// A limit-window event worth telling the user about.
public enum LimitEvent: Equatable, Sendable {
    case crossed(Double, LimitWindow, eta: TimeInterval?)
    case reset(LimitWindow)
}

public enum LimitEvents {
    public static let thresholds: [Double] = [80, 90, 100]

    /// Threshold crossings and refills between two consecutive readings of one tool.
    ///
    /// Only once a real prior reading exists (`previous != nil`), so a cold launch at
    /// already-high usage doesn't fire spurious nudges. Weekly and model windows reset
    /// together; one refill is the whole story and the weekly one describes it best.
    public static func detect(previous: UsageSnapshot?, current: UsageSnapshot, now: Date) -> [LimitEvent] {
        guard let previous else { return [] }
        let before = previous.limitWindows
        let after = current.limitWindows
        var events: [LimitEvent] = []

        let refilled = UsageStats.refilledWindows(previous: before, current: after)
        if let window = refilled.first(where: { $0.kind == .weekly }) ?? refilled.first {
            events.append(.reset(window))
        }
        for crossing in UsageStats.crossedWindows(previous: before, current: after, thresholds: thresholds) {
            events.append(.crossed(
                crossing.threshold,
                crossing.window,
                eta: crossing.window.bucket.timeUntilReset(now: now),
            ))
        }
        return events
    }
}

/// Notification identifiers, namespaced by tool so Claude's and Codex's same-named
/// windows ("Weekly") never replace each other.
public enum NotificationIDs {
    public static func threshold(tool: AgentTool, window: LimitWindow, threshold: Double) -> String {
        "\(tool.rawValue)-threshold-\(window.id)-\(Int(threshold))"
    }

    public static func resetReminder(tool: AgentTool) -> String {
        "\(tool.rawValue)-reset-reminder"
    }

    public static func refill(tool: AgentTool, unique: String) -> String {
        "\(tool.rawValue)-refill-\(unique)"
    }

    public static func title(_ title: String, tool: AgentTool) -> String {
        "\(toolName(tool)) · \(title)"
    }

    private static func toolName(_ tool: AgentTool) -> String {
        switch tool {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}
