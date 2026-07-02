import Foundation
import ClaudeMeterCore
import os

/// Watches for quota refreshes and, for each armed + eligible + iTerm2 session,
/// types `continue` into its tab with a small stagger.
///
/// A refill is detected on a single scan, but the gates (live process, eligible
/// transcript tail) may not all hold at that exact instant — and across a wake
/// from sleep the reset is only seen later. So instead of firing once, a refill
/// opens a **retry window** (`AutoResumePlanner`): every scan re-attempts armed
/// sessions that haven't fired yet until each fires or the window closes. A failed
/// attempt un-marks the session so the next scan retries it. Every decision is
/// logged at `.notice` (persisted, unlike `.info`) so a miss is always traceable.
///
/// The pure decision lives in `AutoResumePlanner`; this type only performs the
/// side effects (scheduling, driving iTerm2, notifications, the tty-reuse probe).
@MainActor
final class AutoResumeCoordinator {
    private let armed: ArmedSessions
    private let settings: Settings
    private let driver: TerminalResumeDriver
    private let terminalDetector = TerminalDetector()
    private let staggerSeconds: Double
    private let resumeWindowSeconds: Double
    private let now: () -> Date
    private let notify: (String) -> Void
    private let log = Logger(subsystem: "com.jakubzak.claudemeter", category: "autoresume")

    /// Last seen 5-hour utilization, to detect a refill crossing.
    private var lastUtilization: Double?
    /// The active retry window (nil between refills).
    private var window: ResumeWindow?

    init(armed: ArmedSessions,
         settings: Settings,
         driver: TerminalResumeDriver = ITermDriver(),
         staggerSeconds: Double = 1.5,
         resumeWindowSeconds: Double = 300,
         now: @escaping () -> Date = Date.init,
         notify: @escaping (String) -> Void) {
        self.armed = armed
        self.settings = settings
        self.driver = driver
        self.staggerSeconds = staggerSeconds
        self.resumeWindowSeconds = resumeWindowSeconds
        self.now = now
        self.notify = notify
    }

    /// Resolve the owning terminal for a session's cwd (for the UI's arm toggle).
    func terminalKind(forCwd cwd: String,
                      processes: [LiveProcess],
                      paths: @escaping (Int32) -> String?,
                      parents: @escaping (Int32) -> Int32) -> TerminalKind {
        SessionProcessIndex(processes: processes)
            .terminalKind(forCwd: cwd, detector: terminalDetector, paths: paths, parents: parents)
    }

    func handleSnapshot(
        usage: UsageSnapshot?,
        sessions: [SessionUsage],
        processes: [LiveProcess],
        transcriptTail: (String) -> [String],
        paths: @escaping (Int32) -> String?,
        parents: @escaping (Int32) -> Int32
    ) {
        guard settings.autoResumeEnabled else {
            log.debug("skip: master switch off")
            return
        }
        guard let bucket = usage?.fiveHour else {
            log.debug("skip: no 5h usage bucket (not signed in / no data yet)")
            return
        }
        let current = bucket.utilization
        let previous = lastUtilization
        let firedBefore = window?.fired ?? []
        let continueText = settings.normalizedContinueText

        let plan = AutoResumePlanner.plan(
            now: now(),
            previousUtilization: lastUtilization,
            currentUtilization: current,
            window: window,
            windowSeconds: resumeWindowSeconds,
            armedIDs: armed.armed,
            sessions: sessions,
            processes: processes,
            transcriptTail: transcriptTail,
            executablePath: paths,
            parentPID: parents)

        lastUtilization = current
        window = plan.window

        if plan.refillDetected {
            let armedCount = sessions.filter { self.armed.isArmed($0.id) }.count
            log.notice("refill detected (\(previous ?? -1, format: .fixed(precision: 1)) -> \(current, format: .fixed(precision: 1))%); opening \(Int(self.resumeWindowSeconds / 60))-min resume window over \(armedCount, format: .decimal) armed session(s)")
        }

        // Diagnostic: every armed session not fired this cycle, with its reason.
        for skip in plan.skipped {
            log.notice("\(skip.projectName, privacy: .public): waiting — \(skip.reason.detail, privacy: .public)")
        }

        // Schedule each eligible session, staggered.
        var delay = 0.0
        for target in plan.targets {
            log.notice("\(target.projectName, privacy: .public): eligible — scheduling resume on \(target.tty, privacy: .public) in \(delay, format: .fixed(precision: 1))s")
            scheduleResume(
                ResumeTarget(sessionID: target.sessionID, tty: target.tty,
                             continueText: continueText, expectedPID: target.pid,
                             expectedCwd: target.cwd),
                after: delay, projectName: target.projectName)
            delay += staggerSeconds
        }

        // One-time summary when the window closes with sessions that never became eligible.
        if plan.windowExpired {
            let missed = armed.armed.subtracting(firedBefore).count
            if missed > 0 {
                log.notice("resume window closed — \(missed, format: .decimal) armed session(s) never became eligible")
                notify("Auto-resume window ended — \(missed) armed session(s) never became eligible (limit cutoff not detected).")
            }
        }
    }

    private func scheduleResume(_ target: ResumeTarget, after delay: Double, projectName: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // tty-reuse defense (spec): re-verify the tty still maps to the same unique live claude process.
            let live = LibprocProcessProbe().liveClaudeProcesses()
            let onTTY = live.filter { $0.tty == target.tty }
            guard onTTY.count == 1, onTTY[0].pid == target.expectedPID, onTTY[0].cwd == target.expectedCwd else {
                self.log.notice("\(projectName, privacy: .public): skip — terminal changed before resume (tty reuse defense); will retry within window")
                self.window?.fired.remove(target.sessionID)   // allow a later scan to retry
                return
            }
            do {
                try self.driver.resume(target)
                self.log.notice("resumed \(projectName, privacy: .public)")
                self.notify("▶︎ Resumed \(projectName)")
            } catch {
                // Most likely on the first ever fire: macOS Automation (TCC) permission
                // not yet granted. Un-mark so the window keeps retrying.
                self.log.error("\(projectName, privacy: .public): resume FAILED — \(String(describing: error), privacy: .public)")
                self.window?.fired.remove(target.sessionID)
                self.notify("Couldn't resume \(projectName): \(String(describing: error))")
            }
        }
    }
}
