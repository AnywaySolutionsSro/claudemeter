import Foundation

/// One Codex rate-limit window from a transcript's `token_count.rate_limits`
/// (`primary` / `secondary`). Its identity is `windowMinutes`, never its position.
public struct CodexWindowReading: Sendable, Equatable, Codable {
    /// Share of the window already used (0...100), as Codex reports it.
    public let usedPercent: Double
    /// Window length: 300 = 5-hour session, 10080 = weekly.
    public let windowMinutes: Int
    /// When the window rolls over (`resets_at`, epoch seconds); `nil` if not reported.
    public let resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

/// The account's Codex limits as one transcript line — or one live ChatGPT usage
/// fetch — saw them. `observedAt` is that line's timestamp, or the fetch time.
public struct CodexLimitReading: Sendable, Equatable, Codable {
    /// `rate_limits.limit_id` (`"codex"` for the main allowance).
    public let limitID: String
    public let observedAt: Date
    /// Present windows in transcript order (`primary`, then `secondary`).
    public let windows: [CodexWindowReading]
    /// `rate_limit_reached_type` — non-nil once a limit has cut the session off.
    public let reachedType: String?
    /// The ChatGPT plan (`plan_type`), when the live usage endpoint reports it.
    public let planType: String?

    public init(
        limitID: String, observedAt: Date, windows: [CodexWindowReading], reachedType: String?,
        planType: String? = nil,
    ) {
        self.limitID = limitID
        self.observedAt = observedAt
        self.windows = windows
        self.reachedType = reachedType
        self.planType = planType
    }
}
