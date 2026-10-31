import Foundation

/// One rate-limit window an account actually has right now.
///
/// Plans differ in which windows exist, and an account can gain or lose one mid-run:
/// verified Ultra has no session window, an unverified one has a temporary session
/// window until verification lifts it. So nothing should be keyed on a plan name, and
/// two readings are only comparable window by window — `label` is that identity.
public struct LimitWindow: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case session, weekly, model
    }

    public let kind: Kind
    /// Short, stable label: "Session", "Weekly", or the model's ("Fable").
    public let label: String
    public let bucket: UsageBucket

    public init(kind: Kind, label: String, bucket: UsageBucket) {
        self.kind = kind
        self.label = label
        self.bucket = bucket
    }

    public var id: String { label }

    /// How a sentence refers to this window: "your weekly limit".
    public var phrase: String {
        switch kind {
        case .session: "session window"
        case .weekly: "weekly limit"
        case .model: "\(label) weekly limit"
        }
    }

    /// The word for this window's allowance: "Out of weekly budget".
    public var budgetName: String {
        switch kind {
        case .session: "session"
        case .weekly: "weekly"
        case .model: label
        }
    }
}

public extension UsageSnapshot {
    /// Every window this reading has, in display order.
    var limitWindows: [LimitWindow] {
        var windows: [LimitWindow] = []
        if let fiveHour { windows.append(LimitWindow(kind: .session, label: "Session", bucket: fiveHour)) }
        if let sevenDay { windows.append(LimitWindow(kind: .weekly, label: "Weekly", bucket: sevenDay)) }
        for limit in allModelWeekly {
            windows.append(LimitWindow(kind: .model, label: limit.label, bucket: limit.bucket))
        }
        return windows
    }

    /// The account-wide window stopping all work, or `nil` if work can proceed. When
    /// both are exhausted it is the one that resets last, since only that reset lets
    /// work continue. A model window never blocks: other models still work.
    var blockingWindow: LimitWindow? {
        limitWindows
            .filter { $0.kind != .model && UsageStats.isExhausted($0.bucket.utilization) }
            .max { ($0.bucket.resetsAt ?? .distantPast) < ($1.bucket.resetsAt ?? .distantPast) }
    }
}
