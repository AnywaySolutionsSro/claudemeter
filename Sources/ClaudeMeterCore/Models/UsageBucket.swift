import Foundation

/// A single rate-limit window as reported by Anthropic's `/api/oauth/usage` endpoint.
///
/// `utilization` is the percentage of the window already consumed (0...100), matching
/// the server-side number Claude Code shows in `/usage`. `resetsAt` is when the window
/// rolls over. Both come straight from the API — there is no local estimation.
public struct UsageBucket: Equatable, Sendable {
    public let utilization: Double
    public let resetsAt: Date?
    public let status: String?

    public init(utilization: Double, resetsAt: Date?, status: String? = nil) {
        self.utilization = max(0, min(100, utilization))
        self.resetsAt = resetsAt
        self.status = status
    }

    /// Percentage of the window already used (0...100).
    public var percentUsed: Double { utilization }

    /// Percentage of the window still available (0...100) — the "left" number.
    public var percentRemaining: Double { max(0, 100 - utilization) }

    /// Seconds until this window resets, or `nil` if the API didn't supply a reset time.
    public func timeUntilReset(now: Date) -> TimeInterval? {
        guard let resetsAt else { return nil }
        return max(0, resetsAt.timeIntervalSince(now))
    }
}
