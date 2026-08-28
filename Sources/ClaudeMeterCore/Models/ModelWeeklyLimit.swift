import Foundation

/// A per-model weekly window from the usage endpoint's `limits[]` array
/// (`kind == "weekly_scoped"`). The label is server-supplied
/// (`scope.model.display_name`, e.g. "Fable"), so new model tiers show up
/// without a code change; `isActive` is Anthropic's own flag for the window
/// that is currently the binding constraint.
public struct ModelWeeklyLimit: Equatable, Sendable {
    public let label: String
    public let bucket: UsageBucket
    public let isActive: Bool

    public init(label: String, bucket: UsageBucket, isActive: Bool) {
        self.label = label
        self.bucket = bucket
        self.isActive = isActive
    }
}
