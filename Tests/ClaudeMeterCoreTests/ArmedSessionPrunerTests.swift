import Foundation
import Testing
@testable import ClaudeMeterCore

/// Armed sessions whose terminal died (tab closed, /clear started a new session
/// id) must disarm themselves — otherwise they pin dead sessions in the widget
/// forever. Pruning requires several consecutive not-running scans so a single
/// transient probe glitch can't disarm everything right before a refill.
@Suite struct ArmedSessionPrunerTests {
    private let pruner = ArmedSessionPruner(missThreshold: 3)

    @Test func runningArmedSessionIsKeptAndMissesReset() {
        let plan = pruner.plan(armed: ["a"], runningIDs: ["a"], previousMisses: ["a": 2])
        #expect(plan.disarm.isEmpty)
        #expect(plan.misses["a"] == nil)
    }

    @Test func notRunningAccumulatesMissesWithoutDisarmingEarly() {
        var misses: [String: Int] = [:]
        for expected in 1...2 {
            let plan = pruner.plan(armed: ["a"], runningIDs: [], previousMisses: misses)
            #expect(plan.disarm.isEmpty)
            #expect(plan.misses["a"] == expected)
            misses = plan.misses
        }
    }

    @Test func disarmsAfterThresholdConsecutiveMisses() {
        let plan = pruner.plan(armed: ["a"], runningIDs: [], previousMisses: ["a": 2])
        #expect(plan.disarm == ["a"])
        #expect(plan.misses["a"] == nil)
    }

    @Test func recoveryBeforeThresholdClearsTheCount() {
        // Two misses, then the session is seen running again, then gone once more:
        // the count restarts from scratch.
        let afterRecovery = pruner.plan(armed: ["a"], runningIDs: ["a"], previousMisses: ["a": 2])
        let plan = pruner.plan(armed: ["a"], runningIDs: [], previousMisses: afterRecovery.misses)
        #expect(plan.disarm.isEmpty)
        #expect(plan.misses["a"] == 1)
    }

    @Test func disarmedOrUnknownIDsAreDroppedFromState() {
        // "b" is no longer armed at all — its stale miss count must not leak.
        let plan = pruner.plan(armed: ["a"], runningIDs: ["a"], previousMisses: ["b": 2])
        #expect(plan.misses.isEmpty)
    }

    @Test func multipleArmedSessionsAreTrackedIndependently() {
        let plan = pruner.plan(armed: ["dead", "alive"], runningIDs: ["alive"],
                               previousMisses: ["dead": 2])
        #expect(plan.disarm == ["dead"])
        #expect(plan.misses["alive"] == nil)
    }
}
