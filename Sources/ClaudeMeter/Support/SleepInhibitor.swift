import Foundation
import IOKit.pwr_mgt
import os

/// Holds a single IOKit power assertion that keeps the Mac awake while at least
/// one session is armed. Idempotent: repeated `update(active:)` calls with the
/// same value are no-ops.
@MainActor
final class SleepInhibitor {
    private var assertionID: IOPMAssertionID = 0
    private var holding = false
    private let log = Logger(subsystem: "com.jakubzak.claudemeter", category: "sleep")

    var isHolding: Bool { holding }

    func update(active: Bool) {
        if active { acquire() } else { release() }
    }

    private func acquire() {
        guard !holding else { return }
        var id: IOPMAssertionID = 0
        let reason = "ClaudeMeter auto-resume armed" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason, &id)
        guard result == kIOReturnSuccess else {
            log.error("failed to create power assertion: \(result)")
            return
        }
        assertionID = id
        holding = true
    }

    private func release() {
        guard holding else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        holding = false
    }
}
