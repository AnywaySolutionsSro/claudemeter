import Foundation

/// The small decisions behind how Codex shows up next to Claude: whether the menu bar
/// stacks a Codex line, the note on a window whose reset passed unseen, and the activity line.
public enum CodexDisplay {
    /// Whether the menu bar stacks a Codex line under Claude's. Decided by the setting
    /// and Codex's presence only — never by whether a reading exists — so the status
    /// item's width doesn't change from one scan to the next.
    public static func showsCodexLine(enabled: Bool, present: Bool) -> Bool {
        enabled && present
    }

    /// The Codex window the menu-bar line shows. The burn-rate mode (`showsBurn`)
    /// shows the window Codex's burn is measured on (session, else weekly — the
    /// `UsageSample` rule), so its ETA is compared with that window's own reset;
    /// every other mode shows the most constrained window.
    public static func menuBarBucket(showsBurn: Bool, limits: UsageSnapshot?) -> UsageBucket? {
        showsBurn ? limits?.primary : limits?.mostConstrained
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
        let moment = moment(resetsAt, now: now, style: style, timeZone: timeZone, locale: locale)
        return "reset at \(moment) · no reading since"
    }

    /// How old a Codex reading may get before the widget says so.
    public static let readingAgeThreshold: TimeInterval = 3600

    /// `as of 06:00` (`as of 14 Jan 22:00` from an earlier day) for a Codex limit
    /// reading older than an hour — Codex limits only refresh when a Codex turn runs,
    /// so an old ring is easy to mistake for a live one. `nil` while fresh or unknown.
    public static func readingAgeNote(
        asOf: Date?,
        now: Date,
        style: ClockStyle,
        timeZone: TimeZone = .current,
        locale: Locale = .current,
    ) -> String? {
        guard let asOf, now.timeIntervalSince(asOf) > readingAgeThreshold else { return nil }
        return "as of \(moment(asOf, now: now, style: style, timeZone: timeZone, locale: locale))"
    }

    /// The clock time on `now`'s day, else the date and clock time.
    private static func moment(
        _ date: Date, now: Date, style: ClockStyle, timeZone: TimeZone, locale: Locale,
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.isDate(date, inSameDayAs: now)
            ? Formatting.clockTime(date, style: style, timeZone: timeZone, locale: locale)
            : Formatting.dateTime(date, style: style, timeZone: timeZone, locale: locale)
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
