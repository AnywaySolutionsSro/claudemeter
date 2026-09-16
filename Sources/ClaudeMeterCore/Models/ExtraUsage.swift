import Foundation

/// The paid **extra usage** (overage) allowance that bills on top of a Claude
/// subscription, as reported by `/api/oauth/usage`.
///
/// Read-only by design: ClaudeMeter shows what has been spent and hands every
/// money-moving action off to claude.ai. See
/// `docs/superpowers/specs/2026-09-16-extra-usage-design.md`.
public struct ExtraUsage: Equatable, Sendable, Codable {
    public let isEnabled: Bool
    /// Spent so far in the current billing month.
    public let used: Money
    /// The monthly cap, or `nil` when no limit is set.
    public let limit: Money?
    /// Server-supplied percentage of the cap consumed (0–100), when it sends one.
    public let utilization: Double?
    /// The cap has been hit: further requests are refused until it is raised.
    public let capReached: Bool
    /// Raw server reason the allowance is unavailable; never shown to the user as-is.
    public let disabledReason: String?
    /// Whether this account can buy credits at all — gates the "Buy credits" link.
    public let canPurchase: Bool

    public init(
        isEnabled: Bool,
        used: Money,
        limit: Money? = nil,
        utilization: Double? = nil,
        capReached: Bool = false,
        disabledReason: String? = nil,
        canPurchase: Bool = false,
    ) {
        self.isEnabled = isEnabled
        self.used = used
        self.limit = limit
        self.utilization = utilization
        self.capReached = capReached
        self.disabledReason = disabledReason
        self.canPurchase = canPurchase
    }

    /// Percentage of the cap consumed (0–100), preferring the server's own figure and
    /// falling back to the ratio. `nil` when there is no cap to be a percentage of.
    public var percentUsed: Double? {
        if let utilization { return max(0, min(100, utilization)) }
        guard let limit, limit.amountMinor > 0 else { return nil }
        let ratio = Double(used.amountMinor) / Double(limit.amountMinor) * 100
        return max(0, min(100, ratio))
    }

    /// Spending is being refused right now, for whatever reason.
    public var isBlocked: Bool { capReached || disabledReason != nil }

    /// `€75.09 of €110.00`, or `€75.09` when no cap is set.
    public var headline: String {
        guard let limit else { return Formatting.money(used) }
        return "\(Formatting.money(used)) of \(Formatting.money(limit))"
    }

    /// Plain-language explanation when spending is blocked, or `nil` when it isn't.
    ///
    /// The server's `disabled_reason` vocabulary is undocumented and grows over time,
    /// so an unrecognised value degrades to generic copy rather than leaking an enum.
    public var blockedMessage: String? {
        switch disabledReason {
        case "out_of_credits": "Out of usage credits"
        case "org_spend_cap_reached": "Your organisation's spend cap is reached"
        case "org_level_disabled_until": "Turned off by your organisation"
        case "overage_not_provisioned": "Extra usage isn't set up for this account"
        case .some: "Extra usage is paused"
        case nil: capReached ? "Monthly limit reached" : nil
        }
    }
}
