import Foundation

/// One row of the dropdown's usage list: a titled rate-limit window. `isActive`
/// marks the window the server flags as the binding constraint right now.
public struct UsageWindowRow: Equatable, Sendable, Identifiable {
    public let title: String
    public let bucket: UsageBucket
    public let isActive: Bool

    public init(title: String, bucket: UsageBucket, isActive: Bool = false) {
        self.title = title
        self.bucket = bucket
        self.isActive = isActive
    }

    public var id: String { title }
}
