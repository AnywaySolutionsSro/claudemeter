import Foundation

/// The small decisions behind how Codex shows up next to Claude: the menu-bar pill's
/// figure, the note on a window whose reset passed unseen, and the activity line.
public enum CodexDisplay {
    /// The figure for the green Codex pill: the most constrained window's % left, or
    /// `nil` when the pill is switched off, Codex isn't present, or there is no reading.
    public static func pillPercentLeft(enabled: Bool, present: Bool, limits: UsageSnapshot?) -> Double? {
        guard enabled, present else { return nil }
        return limits?.mostConstrained?.percentRemaining
    }

    /// `reset at 07:00 · no reading since` for a window whose reset has passed with no
    /// newer Codex reading (Codex limits only refresh when a Codex turn runs). Same-day
    /// resets show the clock time, older ones the date too. `nil` for an upcoming reset.
    public static func staleResetNote(
        _ bucket: UsageBucket,
        now: Date,
        style: ClockStyle,
        timeZone: TimeZone = .current,
        locale: Locale = .current,
    ) -> String? {
        guard let resetsAt = bucket.resetsAt, resetsAt <= now else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let moment = calendar.isDate(resetsAt, inSameDayAs: now)
            ? Formatting.clockTime(resetsAt, style: style, timeZone: timeZone, locale: locale)
            : Formatting.dateTime(resetsAt, style: style, timeZone: timeZone, locale: locale)
        return "reset at \(moment) · no reading since"
    }

    /// `2 running · 1 armed`, counting Codex sessions only.
    public static func activityLine(sessions: [SessionUsage], armedIDs: Set<String>) -> String {
        let codex = sessions.filter { $0.effectiveTool == .codex }
        let running = codex.filter { $0.running == .running }.count
        let armed = codex.filter { armedIDs.contains($0.id) }.count
        return "\(running) running · \(armed) armed"
    }
}

/// A widget gauge together with the tool it belongs to. Claude's and Codex's gauges
/// both have a "Weekly" label, so the label alone never identifies a ring.
public struct ToolGauge: Equatable, Sendable, Identifiable {
    public let tool: AgentTool
    public let gauge: UsageGauge

    public init(tool: AgentTool, gauge: UsageGauge) {
        self.tool = tool
        self.gauge = gauge
    }

    public var id: String { "\(tool.rawValue)-\(gauge.label)" }
}

public extension SessionSnapshot {
    /// Whether Codex appears in this snapshot at all (limits or sessions). Without it
    /// the widget renders exactly as it did before Codex support.
    var includesCodex: Bool {
        codexGauges != nil || sessions.contains { $0.effectiveTool == .codex }
    }

    /// The rings a gauge row shows: Claude's, then Codex's, at most `limit`. With Codex
    /// present Claude's per-model windows give way first, but Claude keeps at least two.
    func ringGauges(limit: Int) -> [ToolGauge] {
        let codex = (codexGauges ?? []).map { ToolGauge(tool: .codex, gauge: $0) }
        let claudeSlots = max(limit - codex.count, min(2, limit))
        let claude = usageGauges.prefix(claudeSlots).map { ToolGauge(tool: .claude, gauge: $0) }
        return Array((claude + codex).prefix(limit))
    }
}
