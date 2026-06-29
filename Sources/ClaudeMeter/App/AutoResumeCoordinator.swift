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
        guard settings.autoResumeEnabled else { return }
        guard let bucket = usage?.fiveHour else { return }
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

        firedThisCrossing.removeAll()
        let index = SessionProcessIndex(processes: processes)
        let continueText = settings.normalizedContinueText
        var delay = 0.0

        for session in sessions where armed.isArmed(session.id) {
            guard !firedThisCrossing.contains(session.id) else { continue }

            // Map session -> unique live process by cwd.
            guard let proc = index.process(forCwd: session.projectPath) else {
                notify("Skipped \(session.projectName): no unique live terminal found.")
                continue
            }
            guard let tty = proc.tty else {
                notify("Skipped \(session.projectName): no controlling tty.")
                continue
            }
            // Security: reject any value that is not a real tty device path.
            guard tty.hasPrefix("/dev/tty") else {
                notify("Skipped \(session.projectName): unexpected tty \(tty).")
                continue
            }
            // Must be iTerm2.
            let kind = terminalDetector.detect(startPID: proc.pid,
                                               executablePathForPID: paths,
                                               parentPIDForPID: parents)
            guard kind.isDrivable else {
                notify("Skipped \(session.projectName): \(kind.displayName) not supported yet.")
                continue
            }
            // Eligibility gate over the transcript tail. The live process means
            // "alive", but we pass isRunning=false because resolver-running is
            // about token activity; the tail tells us if a turn is in flight.
            let eligibility = detector.classify(tailLines: transcriptTail(session.id), isRunning: false)
            guard eligibility.shouldFire else { continue }

            let target = ResumeTarget(sessionID: session.id, tty: tty, continueText: continueText)
            firedThisCrossing.insert(session.id)
            scheduleResume(target, after: delay, projectName: session.projectName)
            delay += staggerSeconds
        }
    }

    private func scheduleResume(_ target: ResumeTarget, after delay: Double, projectName: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            do {
                try self.driver.resume(target)
                self.log.log("resumed \(projectName, privacy: .public)")
            } catch {
                self.notify("Couldn't resume \(projectName): \(String(describing: error))")
            }
        }
    }
}
