import Foundation
import ClaudeMeterCore
import os

/// Watches for quota refreshes and, for each armed + eligible + iTerm2 session,
/// types `continue` into its tab with a small stagger. Pure decision inputs are
/// passed in by the caller so this stays unit-test friendly via a mock driver.
@MainActor
final class AutoResumeCoordinator {
    private let armed: ArmedSessions
    private let settings: Settings
    private let driver: TerminalResumeDriver
    private let detector = CutoffDetector()
    private let terminalDetector = TerminalDetector()
    private let staggerSeconds: Double
    private let notify: (String) -> Void
    private let log = Logger(subsystem: "com.jakubzak.claudemeter", category: "autoresume")

    /// Last seen 5-hour utilization, to detect a refill crossing.
    private var lastUtilization: Double?
    /// Sessions already fired during the current low-utilization window.
    private var firedThisCrossing: Set<String> = []

    init(armed: ArmedSessions,
         settings: Settings,
         driver: TerminalResumeDriver = ITermDriver(),
         staggerSeconds: Double = 1.5,
         notify: @escaping (String) -> Void) {
        self.armed = armed
        self.settings = settings
        self.driver = driver
        self.staggerSeconds = staggerSeconds
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
        defer { lastUtilization = current }

        // A refill: utilization dropped meaningfully since last cycle.
        let refilled = UsageStats.didRefill(
            previousUtilization: lastUtilization, currentUtilization: current)
        if !refilled {
            // A new session meaningfully raised utilization (not measurement noise) -> allow the next crossing to fire again.
            if let last = lastUtilization, current >= last + 10 { firedThisCrossing.removeAll() }
            return
        }

        let armedCount = sessions.filter { armed.isArmed($0.id) }.count
        log.info("refill detected (\(self.lastUtilization ?? -1, format: .fixed(precision: 1)) -> \(current, format: .fixed(precision: 1))%); evaluating \(armedCount, format: .decimal) armed session(s)")
        firedThisCrossing.removeAll()
        let index = SessionProcessIndex(processes: processes)
        let continueText = settings.normalizedContinueText
        var delay = 0.0

        for session in sessions where armed.isArmed(session.id) {
            guard !firedThisCrossing.contains(session.id) else { continue }

            let name = session.projectName
            // Map session -> unique live process by cwd.
            guard let proc = index.process(forCwd: session.projectPath) else {
                log.info("\(name, privacy: .public): skip — no unique live terminal for cwd")
                notify("Skipped \(name): no unique live terminal found.")
                continue
            }
            guard let tty = proc.tty else {
                log.info("\(name, privacy: .public): skip — no controlling tty")
                notify("Skipped \(name): no controlling tty.")
                continue
            }
            // Security: reject any value that is not a real tty device path.
            guard tty.hasPrefix("/dev/tty") else {
                log.info("\(name, privacy: .public): skip — unexpected tty \(tty, privacy: .public)")
                notify("Skipped \(name): unexpected tty \(tty).")
                continue
            }
            // Must be iTerm2.
            let kind = terminalDetector.detect(startPID: proc.pid,
                                               executablePathForPID: paths,
                                               parentPIDForPID: parents)
            guard kind.isDrivable else {
                log.info("\(name, privacy: .public): skip — terminal \(kind.displayName, privacy: .public) not drivable")
                notify("Skipped \(name): \(kind.displayName) not supported yet.")
                continue
            }
            // Eligibility gate over the transcript tail. The live process means
            // "alive", but we pass isRunning=false because resolver-running is
            // about token activity; the tail tells us if a turn is in flight.
            let eligibility = detector.classify(tailLines: transcriptTail(session.id), isRunning: false)
            guard eligibility.shouldFire else {
                log.info("\(name, privacy: .public): skip — not eligible (\(String(describing: eligibility), privacy: .public))")
                continue
            }

            let target = ResumeTarget(sessionID: session.id, tty: tty, continueText: continueText,
                                       expectedPID: proc.pid, expectedCwd: proc.cwd)
            firedThisCrossing.insert(session.id)
            log.info("\(name, privacy: .public): eligible — scheduling resume on \(tty, privacy: .public) in \(delay, format: .fixed(precision: 1))s")
            scheduleResume(target, after: delay, projectName: name)
            delay += staggerSeconds
        }
    }

    private func scheduleResume(_ target: ResumeTarget, after delay: Double, projectName: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // tty-reuse defense (spec): re-verify the tty still maps to the same unique live claude process.
            let live = LibprocProcessProbe().liveClaudeProcesses()
            let onTTY = live.filter { $0.tty == target.tty }
            guard onTTY.count == 1, onTTY[0].pid == target.expectedPID, onTTY[0].cwd == target.expectedCwd else {
                self.log.info("\(projectName, privacy: .public): skip — terminal changed before resume (tty reuse defense)")
                self.notify("Skipped \(projectName): terminal changed before resume; not typing.")
                return
            }
            do {
                try self.driver.resume(target)
                self.log.log("resumed \(projectName, privacy: .public)")
            } catch {
                // Most likely cause on the first ever fire: macOS Automation (TCC)
                // permission not yet granted to control iTerm2.
                self.log.error("\(projectName, privacy: .public): resume FAILED — \(String(describing: error), privacy: .public)")
                self.notify("Couldn't resume \(projectName): \(String(describing: error))")
            }
        }
    }
}
