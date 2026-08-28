import Foundation

/// A time-bounded window during which armed sessions are (re)attempted after a
/// detected quota refill. The window is what makes a one-shot refill robust: a
/// refill is detected on a single scan, but the gates (live process, eligible
/// transcript tail) may not all be satisfied at that exact instant. The window
/// lets each later scan retry any armed session that hasn't fired yet, until it
/// fires or the window closes. Pure value type so it threads through `plan(...)`.
public struct ResumeWindow: Equatable, Sendable {
    /// When the window stops retrying.
    public var deadline: Date
    /// Sessions already scheduled this window (never retried, to avoid double `continue`).
    public var fired: Set<String>

    public init(deadline: Date, fired: Set<String> = []) {
        self.deadline = deadline
        self.fired = fired
    }
}

/// One armed session that passed every gate this cycle and should be nudged now.
/// The caller turns this into a `ResumeTarget` and applies the inter-session stagger.
public struct PlannedResume: Equatable, Sendable {
    public let sessionID: String
    public let projectName: String
    public let tty: String
    public let pid: Int32
    public let cwd: String

    public init(sessionID: String, projectName: String, tty: String, pid: Int32, cwd: String) {
        self.sessionID = sessionID
        self.projectName = projectName
        self.tty = tty
        self.pid = pid
        self.cwd = cwd
    }
}

/// Why an armed session was not nudged this cycle. Surfaced for diagnostics so a
/// silent miss can be traced (the old coordinator swallowed the eligibility skip).
public enum ResumeSkipReason: Equatable, Sendable {
    case noUniqueProcess
    case noControllingTTY
    case unexpectedTTY(String)
    case notDrivable(String)
    case notEligible(String)

    public var detail: String {
        switch self {
        case .noUniqueProcess: "no unique live terminal for cwd"
        case .noControllingTTY: "no controlling tty"
        case let .unexpectedTTY(t): "unexpected tty \(t)"
        case let .notDrivable(kind): "\(kind) not drivable"
        case let .notEligible(state): "not eligible (\(state))"
        }
    }
}

public struct ResumeSkip: Equatable, Sendable {
    public let sessionID: String
    public let projectName: String
    public let reason: ResumeSkipReason

    public init(sessionID: String, projectName: String, reason: ResumeSkipReason) {
        self.sessionID = sessionID
        self.projectName = projectName
        self.reason = reason
    }
}

/// The result of one planning cycle.
public struct ResumePlan: Equatable, Sendable {
    /// Updated window state (`nil` means no active window).
    public let window: ResumeWindow?
    /// A refill was newly detected this cycle (for logging / a one-time notification).
    public let refillDetected: Bool
    /// Sessions to nudge now, in order; the caller applies the stagger.
    public let targets: [PlannedResume]
    /// Armed sessions skipped this cycle, with reasons (diagnostic).
    public let skipped: [ResumeSkip]
    /// True on the cycle where the window expired with armed sessions still unfired.
    public let windowExpired: Bool
}

/// Pure decision core of the auto-resume feature. No AppKit, no Keychain, no
/// libproc: the PID→path / PID→parent lookups and transcript tail are injected,
/// exactly like `TerminalDetector`, so the whole policy is unit-testable.
public enum AutoResumePlanner {
    public static func plan(
        now: Date,
        previousUtilization: Double?,
        currentUtilization: Double,
        window: ResumeWindow?,
        windowSeconds: Double,
        dropThreshold: Double = 25,
        lastRefillAt: Date? = nil,
        refillCooldownSeconds: Double = 3600,
        armedIDs: Set<String>,
        sessions: [SessionUsage],
        processes: [LiveProcess],
        transcriptTail: (String) -> [String],
        executablePath: (Int32) -> String?,
        parentPID: (Int32) -> Int32,
    ) -> ResumePlan {
        var refilled = UsageStats.didRefill(
            previousUtilization: previousUtilization,
            currentUtilization: currentUtilization,
            dropThreshold: dropThreshold,
        )
        // A real 5h refill cannot recur within the cooldown; a second "drop" that
        // soon is a stale-vs-fresh usage reading flapping (e.g. a cached snapshot
        // served during rate-limit backoff) and must not reopen the window.
        if refilled, let last = lastRefillAt, now < last.addingTimeInterval(refillCooldownSeconds) {
            refilled = false
        }

        // A fresh refill opens (or restarts) the retry window.
        var window = window
        if refilled {
            window = ResumeWindow(deadline: now.addingTimeInterval(windowSeconds), fired: [])
        }

        // No active window -> nothing to do this cycle.
        guard var active = window else {
            return ResumePlan(window: nil, refillDetected: refilled,
                              targets: [], skipped: [], windowExpired: false)
        }

        // Window elapsed -> close it, reporting whether any armed session never fired.
        if now > active.deadline {
            let unfired = armedIDs.subtracting(active.fired)
            return ResumePlan(window: nil, refillDetected: refilled,
                              targets: [], skipped: [], windowExpired: !unfired.isEmpty)
        }

        // Map cwd -> unique live process (ambiguous cwd => skip, never type into the wrong tab).
        let byCwd = Dictionary(grouping: processes, by: { $0.cwd })
        let detector = CutoffDetector()
        let terminals = TerminalDetector()
        var targets: [PlannedResume] = []
        var skipped: [ResumeSkip] = []

        for session in sessions where armedIDs.contains(session.id) {
            if active.fired.contains(session.id) { continue }
            let name = session.projectName

            func skip(_ reason: ResumeSkipReason) {
                skipped.append(ResumeSkip(sessionID: session.id, projectName: name, reason: reason))
            }

            guard let matches = byCwd[session.projectPath], matches.count == 1 else {
                skip(.noUniqueProcess); continue
            }
            let proc = matches[0]
            guard let tty = proc.tty else { skip(.noControllingTTY); continue }
            // Security: reject anything that is not a real tty device path.
            guard tty.hasPrefix("/dev/tty") else { skip(.unexpectedTTY(tty)); continue }

            let kind = terminals.detect(startPID: proc.pid,
                                        executablePathForPID: executablePath,
                                        parentPIDForPID: parentPID)
            guard kind.isDrivable else { skip(.notDrivable(kind.displayName)); continue }

            // The live process means "alive"; isRunning=false because the tail, not
            // token activity, tells us whether a turn is in flight.
            let eligibility = detector.classify(tailLines: transcriptTail(session.id), isRunning: false)
            guard eligibility.shouldFire else {
                skip(.notEligible(String(describing: eligibility))); continue
            }

            active.fired.insert(session.id)
            targets.append(PlannedResume(sessionID: session.id, projectName: name,
                                         tty: tty, pid: proc.pid, cwd: proc.cwd))
        }

        return ResumePlan(window: active, refillDetected: refilled,
                          targets: targets, skipped: skipped, windowExpired: false)
    }
}
