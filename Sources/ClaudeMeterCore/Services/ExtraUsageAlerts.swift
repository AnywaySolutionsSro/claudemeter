import Foundation

/// A threshold worth telling the user about, at most once per billing period.
public enum ExtraUsageAlert: String, Codable, Sendable, CaseIterable {
    /// The month's first paid request — the moment spending begins.
    case spendingStarted
    /// 80% of the monthly cap consumed.
    case nearingCap
    /// The cap is hit; requests are refused until it is raised.
    case capReached

    public struct Message: Equatable, Sendable {
        public let title: String
        public let body: String
    }

    public func message(for usage: ExtraUsage) -> Message {
        switch self {
        case .spendingStarted:
            let cap = usage.limit.map { " of \(Formatting.money($0)) this month" } ?? ""
            return Message(
                title: "Extra usage started 💳",
                body: "Your plan limit is covered by paid extra usage now — \(Formatting.money(usage.used))\(cap).",
            )
        case .nearingCap:
            return Message(
                title: "Extra usage at 80%",
                body: "\(usage.headline) spent this month.",
            )
        case .capReached:
            let cap = usage.limit.map { Formatting.money($0) } ?? Formatting.money(usage.used)
            return Message(
                title: "Extra usage cap reached ⛔️",
                body: "You've hit \(cap) — Claude waits for your plan limit to reset until you raise it.",
            )
        }
    }
}

/// Decides which extra-usage alerts a new reading has just crossed.
///
/// Pure and fully tested on purpose. The hard part is that the API supplies **no reset
/// date** for the monthly spend window (`daily` and `weekly` are null and `spend` carries
/// no `resets_at`), so the only evidence a new billing period began is the spent amount
/// **dropping** — the same shape of signal `UsageStats.didRefill` relies on.
public enum ExtraUsageAlerts {
    /// Percentage of the cap at which the heads-up fires.
    public static let nearingCapPercent: Double = 80

    public typealias Outcome = (fire: [ExtraUsageAlert], notified: Set<ExtraUsageAlert>)

    /// - Parameters:
    ///   - previous: the last reading, or `nil` for the first of this run. With no prior
    ///     reading nothing can be said to have been *crossed*, so the result only seeds
    ///     what already holds — otherwise every launch mid-month would notify again.
    ///   - current: the new reading, or `nil` if this poll produced none (which must
    ///     change nothing at all).
    ///   - notified: alerts already delivered this billing period.
    public static func decide(
        previous: ExtraUsage?, current: ExtraUsage?, notified: Set<ExtraUsageAlert>,
    ) -> Outcome {
        guard let current else { return ([], notified) }

        // A drop is a new billing period: forget what was delivered for the old one.
        let rolledOver = previous.map { current.used.decimalValue < $0.used.decimalValue } ?? false
        var delivered = rolledOver ? [] : notified

        guard current.isEnabled else { return ([], delivered) }

        let reached = reachedAlerts(current)
        // The first reading of a run seeds silently; a rollover is a real crossing.
        guard previous != nil || rolledOver else { return ([], reached) }

        let fire = ExtraUsageAlert.allCases.filter { reached.contains($0) && !delivered.contains($0) }
        delivered.formUnion(reached)
        return (fire, delivered)
    }

    /// Which thresholds this reading satisfies, regardless of what was delivered before.
    private static func reachedAlerts(_ usage: ExtraUsage) -> Set<ExtraUsageAlert> {
        var reached: Set<ExtraUsageAlert> = []
        if !usage.used.isZero { reached.insert(.spendingStarted) }
        if let percent = usage.percentUsed {
            if percent >= nearingCapPercent { reached.insert(.nearingCap) }
            if percent >= 100 { reached.insert(.capReached) }
        }
        if usage.capReached { reached.insert(.capReached) }
        return reached
    }
}
