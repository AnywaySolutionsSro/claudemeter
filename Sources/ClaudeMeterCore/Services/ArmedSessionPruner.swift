import Foundation

/// The result of one pruning pass: which armed sessions to disarm now, and the
/// carried-over consecutive-miss counts for the rest.
public struct ArmedPrunePlan: Equatable, Sendable {
    public let disarm: Set<String>
    public let misses: [String: Int]

    public init(disarm: Set<String>, misses: [String: Int]) {
        self.disarm = disarm
        self.misses = misses
    }
}

/// Auto-disarms armed sessions whose terminal died (tab closed, or /clear
/// started a new session id in the same process). Without this, an armed dead
/// session stays pinned in the widget forever, and arming drifts away from the
/// "latest running session per project" the user actually means.
///
/// Disarm requires `missThreshold` CONSECUTIVE scans of not-running: a single
/// transient probe glitch must never mass-disarm right before a refill fires.
public struct ArmedSessionPruner: Sendable {
    private let missThreshold: Int

    public init(missThreshold: Int = 3) {
        self.missThreshold = missThreshold
    }

    public func plan(
        armed: Set<String>,
        runningIDs: Set<String>,
        previousMisses: [String: Int]
    ) -> ArmedPrunePlan {
        var disarm: Set<String> = []
        var misses: [String: Int] = [:]

        for id in armed {
            if runningIDs.contains(id) { continue }   // alive: count resets by omission
            let count = (previousMisses[id] ?? 0) + 1
            if count >= missThreshold {
                disarm.insert(id)
            } else {
                misses[id] = count
            }
        }
        return ArmedPrunePlan(disarm: disarm, misses: misses)
    }
}
