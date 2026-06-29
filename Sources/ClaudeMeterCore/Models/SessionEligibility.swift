import Foundation

/// Whether an armed session should be nudged to continue at a quota refresh.
public enum SessionEligibility: Equatable, Sendable {
    /// Idle and stopped at the usage limit with work pending — fire `continue`.
    case eligibleCutoff
    /// Idle and cleanly finished (no pending work) — never fire; stays armed.
    case awaitingUserInput
    /// Cleanly finished — never fire.
    case cleanlyFinished
    /// A turn is in flight / process busy — never fire.
    case running
    /// Could not be determined — never fire.
    case unknown

    /// The only state the coordinator fires on in v1.
    public var shouldFire: Bool { self == .eligibleCutoff }
}
