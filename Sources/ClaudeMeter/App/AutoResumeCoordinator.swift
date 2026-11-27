import ClaudeMeterCore
import Foundation
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
///
/// Claude and Codex run **independent** plans: each tool has its own baseline, retry
/// window, refill cooldown and failure-notification gate (`ToolState`), its own refill
/// gate (`AutoResumePlanner.gate` / `CodexLimits.gate`) and only ever targets its own
/// sessions and processes. The armed set is shared (session IDs are unique). Codex
/// decisions log in the same category, prefixed `codex:`.
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

    /// Per-tool auto-resume state.
    /// Bumped when a tool is hidden; a scheduled resume from an earlier epoch is dropped.
    private var epochs: [AgentTool: Int] = [:]

    private struct ToolState {
        /// The windows of the last reading, to detect a refill of any of them.
        var lastWindows: [LimitWindow] = []
        /// When that reading was taken (Codex: a window refills when its reset passes
        /// between two scans).
        var lastScanAt: Date?
        /// The active retry window (nil between refills).
        var window: ResumeWindow?
        /// When the last accepted refill opened a window (feeds the planner's
        /// cooldown so flapping usage readings can't reopen windows all day).
        var lastRefillAt: Date?
        /// Sessions whose failure was already notified this window. The retry loop
        /// attempts every scan (~10s for 5 min); without this gate a persistent
        /// failure (e.g. missing Automation permission) fires dozens of identical
        /// notifications per window. Retries still log at .error every attempt.
        var notifiedFailures: Set<String> = []
        /// The blocking window whose armed-session tails were already logged (Codex:
        /// the cutoff format is unverified, so the first real one is worth a look).
        var loggedBlock: String?
    }

    private var states: [AgentTool: ToolState] = [:]
    /// When the Mac went to sleep, so a window open across the sleep can be extended
    /// by the slept time instead of expiring while nothing could run.
    private var sleptAt: Date?

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

    /// User-initiated test fire: runs the exact resume pipeline for one session —
    /// `processes` must be the session's own tool's processes —
    /// process match, tty validation, terminal detection, tty-reuse defense, the
    /// AppleScript drive — bypassing only refill detection and the cutoff gate.
    /// This is the debugging path for e.g. Automation (TCC) permission: outcome
    /// is always reported via a notification.
    func testResume(session: SessionUsage,
                    processes: [LiveProcess],
                    paths: @escaping (Int32) -> String?,
                    parents: @escaping (Int32) -> Int32) {
        let name = session.projectName
        let index = SessionProcessIndex(processes: processes)
        guard let proc = index.process(forCwd: session.projectPath) else {
            log.notice("TEST \(name, privacy: .public): no unique live terminal for cwd")
            notify("Test \(name): no unique live terminal found for its folder.")
            return
        }
        guard let tty = proc.tty, tty.hasPrefix("/dev/tty") else {
            log.notice("TEST \(name, privacy: .public): missing/unexpected tty")
            notify("Test \(name): no controlling tty.")
            return
        }
        let kind = terminalDetector.detect(startPID: proc.pid,
                                           executablePathForPID: paths, parentPIDForPID: parents)
        guard kind.isDrivable else {
            log.notice("TEST \(name, privacy: .public): terminal \(kind.displayName, privacy: .public) not drivable")
            notify("Test \(name): \(kind.displayName) is not supported (iTerm2 only).")
            return
        }
        let tool = session.effectiveTool
        log
            .notice(
                "\(Self.tag(tool), privacy: .public)TEST resume: typing into \(name, privacy: .public) on \(tty, privacy: .public)",
            )
        states[tool, default: ToolState()].notifiedFailures.remove(session.id) // a test always reports its outcome
        scheduleResume(
            ResumeTarget(sessionID: session.id, tty: tty,
                         continueText: settings.normalizedContinueText,
                         expectedPID: proc.pid, expectedCwd: proc.cwd),
            after: 0, projectName: name, tool: tool,
        )
    }

    /// Resolve the owning terminal for a session's cwd (for the UI's arm toggle).
    func terminalKind(forCwd cwd: String,
                      processes: [LiveProcess],
                      paths: @escaping (Int32) -> String?,
                      parents: @escaping (Int32) -> Int32) -> TerminalKind {
        SessionProcessIndex(processes: processes)
            .terminalKind(forCwd: cwd, detector: terminalDetector, paths: paths, parents: parents)
    }

    /// The account changed (sign-out): the last utilization belongs to someone else.
    /// Only that tool's state is dropped — a Claude sign-out says nothing about Codex.
    func resetBaseline(tool: AgentTool = .claude) {
        states[tool] = nil
    }

    func noteSleep() { sleptAt = now() }

    /// A window is wall-clock bounded; time asleep is not time in which a session
    /// could have become eligible, so give it back.
    func noteWake() {
        guard let sleptAt else { return }
        self.sleptAt = nil
        let slept = now().timeIntervalSince(sleptAt)
        guard slept > 0 else { return }
        for tool in AgentTool.allCases where states[tool]?.window != nil {
            states[tool]?.window?.deadline.addTimeInterval(slept)
            log
                .notice(
                    "\(Self.tag(tool), privacy: .public)wake: extended resume window by \(Int(slept), format: .decimal)s slept",
                )
        }
    }

    /// Log prefix: Codex decisions share the `autoresume` category, prefixed `codex:`.
    private static func tag(_ tool: AgentTool) -> String {
        tool == .codex ? "codex: " : ""
    }

    /// The transcript-tail classifier for a tool's sessions.
    static func classifier(for tool: AgentTool) -> ([String]) -> SessionEligibility {
        switch tool {
        case .claude: { CutoffDetector().classify(tailLines: $0, isRunning: false) }
        case .codex: { CodexCutoffDetector().classify(tailLines: $0, isRunning: false) }
        }
    }

    /// Run one tool's plan for this scan. `sessions` may hold every tool's sessions:
    /// only `tool`'s are planned, and armed sessions of another tool are left out of
    /// this tool's window. `processes` must be `tool`'s own live processes.
    func handleSnapshot(
        tool: AgentTool = .claude,
        usage: UsageSnapshot?,
        sessions: [SessionUsage],
        processes: [LiveProcess],
        transcriptTail: (String) -> [String],
        classify: (([String]) -> SessionEligibility)? = nil,
        scannedAt: Date? = nil,
        codexReached: LimitWindow? = nil,
        paths: @escaping (Int32) -> String?,
        parents: @escaping (Int32) -> Int32,
    ) {
        let tag = Self.tag(tool)
        guard settings.autoResumeEnabled else {
            log.debug("\(tag, privacy: .public)skip: master switch off")
            return
        }
        guard let usage else {
            log.debug("\(tag, privacy: .public)skip: no usage reading (not signed in / no data yet)")
            return
        }
        let partition = ToolResumeGuard.partition(tool: tool, sessions: sessions, armedIDs: armed.armed)
        let toolSessions = partition.sessions
        let armedIDs = partition.armedIDs
        // Codex passes the scan's own time, so a window is judged past-reset at the same
        // instant its snapshot was built; Claude keeps the coordinator's clock.
        let scanAt = scannedAt ?? now()
        var state = states[tool] ?? ToolState()
        defer { states[tool] = state }

        // A refill under an exhausted window resumes nothing useful: `continue` hits
        // that limit again. The baseline still advances, so the blocking window's own
        // reset is what opens the resume window.
        let gate: ResumeGate = switch tool {
        case .claude: AutoResumePlanner.gate(previous: state.lastWindows, current: usage)
        case .codex: CodexLimits.gate(previous: state.lastWindows, previousAt: state.lastScanAt,
                                      current: usage, now: scanAt, reached: codexReached)
        }
        state.lastWindows = usage.limitWindows
        state.lastScanAt = scanAt
        guard case let .clear(refilled) = gate else {
            if case let .blocked(window) = gate {
                log.notice("\(tag, privacy: .public)skip: \(window.label, privacy: .public) window exhausted")
                if tool == .codex, state.loggedBlock != window.id {
                    state.loggedBlock = window.id
                    logCodexTails(toolSessions.filter { armedIDs.contains($0.id) }, transcriptTail: transcriptTail)
                }
            }
            return
        }
        state.loggedBlock = nil
        let firedBefore = state.window?.fired ?? []

        let plan = AutoResumePlanner.plan(
            now: scanAt,
            refillObserved: !refilled.isEmpty,
            window: state.window,
            windowSeconds: resumeWindowSeconds,
            lastRefillAt: state.lastRefillAt,
            armedIDs: armedIDs,
            sessions: toolSessions,
            processes: processes,
            transcriptTail: transcriptTail,
            executablePath: paths,
            parentPID: parents,
            classify: classify ?? Self.classifier(for: tool),
        )

        state.window = plan.window

        if plan.refillDetected {
            let armedCount = toolSessions.filter { self.armed.isArmed($0.id) }.count
            let names = refilled.map(\.label).joined(separator: ", ")
            log
                .notice(
                    "\(tag, privacy: .public)refill detected (\(names, privacy: .public)); opening \(Int(self.resumeWindowSeconds / 60))-min resume window over \(armedCount, format: .decimal) armed session(s)",
                )
            state.lastRefillAt = scanAt
            state.notifiedFailures.removeAll() // a fresh window may notify each session once again
        }

        perform(plan, tool: tool, armedIDs: armedIDs, firedBefore: firedBefore)
    }

    /// Log the plan's skips, schedule its targets (staggered) and report a window that
    /// closed with armed sessions that never became eligible.
    private func perform(_ plan: ResumePlan, tool: AgentTool, armedIDs: Set<String>, firedBefore: Set<String>) {
        let tag = Self.tag(tool)
        let continueText = settings.normalizedContinueText
        // Diagnostic: every armed session not fired this cycle, with its reason.
        for skip in plan.skipped {
            log
                .notice(
                    "\(tag, privacy: .public)\(skip.projectName, privacy: .public): waiting — \(skip.reason.detail, privacy: .public)",
                )
        }

        // Schedule each eligible session, staggered.
        var delay = 0.0
        for target in plan.targets {
            log
                .notice(
                    "\(tag, privacy: .public)\(target.projectName, privacy: .public): eligible — scheduling resume on \(target.tty, privacy: .public) in \(delay, format: .fixed(precision: 1))s",
                )
            scheduleResume(
                ResumeTarget(sessionID: target.sessionID, tty: target.tty,
                             continueText: continueText, expectedPID: target.pid,
                             expectedCwd: target.cwd),
                after: delay, projectName: target.projectName, tool: tool,
            )
            delay += staggerSeconds
        }

        // One-time summary when the window closes with sessions that never became eligible.
        if plan.windowExpired {
            let missed = armedIDs.subtracting(firedBefore).count
            if missed > 0 {
                log
                    .notice(
                        "\(tag, privacy: .public)resume window closed — \(missed, format: .decimal) armed session(s) never became eligible",
                    )
                let what = tool == .codex ? "Codex auto-resume" : "Auto-resume"
                notify(
                    "\(what) window ended — \(missed) armed session(s) never became eligible (limit cutoff not detected).",
                )
            }
        }
    }

    /// The Codex cutoff format is unverified: when a Codex window is exhausted, log
    /// what each armed session's transcript ends with, so the first real cutoff can
    /// be checked against `CodexCutoffDetector`. Once per blocking window.
    private func logCodexTails(_ sessions: [SessionUsage], transcriptTail: (String) -> [String]) {
        for session in sessions {
            let tail = transcriptTail(session.id)
            let verdict = CodexCutoffDetector().classify(tailLines: tail, isRunning: false)
            let last = tail.last.map(Self.entryType) ?? "none"
            log
                .notice(
                    "codex: \(session.projectName, privacy: .public): window exhausted — last entry \(last, privacy: .public), detector says \(String(describing: verdict), privacy: .public)",
                )
        }
    }

    /// `type/payload.type` of one transcript line (content is never logged).
    private static func entryType(_ line: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return "unparseable"
        }
        let type = object["type"] as? String ?? "?"
        let payloadType = (object["payload"] as? [String: Any])?["type"] as? String
        return payloadType.map { "\(type)/\($0)" } ?? type
    }

    private func scheduleResume(_ target: ResumeTarget, after delay: Double, projectName: String,
                                tool: AgentTool) {
        let tag = Self.tag(tool)
        let epoch = epochs[tool, default: 0]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.epochs[tool, default: 0] == epoch else {
                self.log.notice("\(tag, privacy: .public)\(projectName, privacy: .public): skip — tool hidden")
                return
            }
            // tty-reuse defense (spec): re-verify the tty still maps to the same unique
            // live process of this tool, and that no process of the other tool shares it.
            let probe = LibprocProcessProbe()
            let claude = probe.liveClaudeProcesses()
            let codex = probe.liveCodexProcesses()
            let check = ToolResumeGuard.verifyTTY(
                target.tty, expectedPID: target.expectedPID, expectedCwd: target.expectedCwd,
                own: tool == .codex ? codex : claude, other: tool == .codex ? claude : codex,
            )
            guard check == .clear else {
                let reason = check == .sharedWithOtherTool
                    ? "another tool shares tty" : "terminal changed before resume (tty reuse defense)"
                self.log
                    .notice(
                        "\(tag, privacy: .public)\(projectName, privacy: .public): skip — \(reason, privacy: .public); will retry within window",
                    )
                self.states[tool]?.window?.fired.remove(target.sessionID) // allow a later scan to retry
                return
            }
            do {
                try self.driver.resume(target)
                self.log.notice("\(tag, privacy: .public)resumed \(projectName, privacy: .public)")
                self.notify(tool == .codex ? "▶︎ Resumed \(projectName) (Codex)" : "▶︎ Resumed \(projectName)")
            } catch {
                // Most likely on the first ever fire: macOS Automation (TCC) permission
                // not yet granted. Un-mark so the window keeps retrying — but notify
                // only once per session per window (retries log every attempt).
                self.log
                    .error(
                        "\(tag, privacy: .public)\(projectName, privacy: .public): resume FAILED — \(String(describing: error), privacy: .public)",
                    )
                self.states[tool]?.window?.fired.remove(target.sessionID)
                if self.states[tool, default: ToolState()].notifiedFailures.insert(target.sessionID).inserted {
                    self
                        .notify(
                            "Couldn't resume \(projectName): \(String(describing: error)) — retrying quietly; check System Settings → Privacy & Security → Automation if this persists.",
                        )
                }
            }
        }
    }
}

// MARK: - Per-scan entry point

extension AutoResumeCoordinator {
    /// Run the Claude and the Codex plan for one scan, against the live process table.
    /// A tool left out of `tools` (hidden in Settings) is not planned, and its baseline
    /// is dropped so showing it again can't read the gap as a refill.
    func handleScan(claudeUsage: UsageSnapshot?, inputs: UsageContextInputs, tools: [AgentTool] = AgentTool.allCases) {
        let paths: (Int32) -> String? = { LibprocProcessProbe.executablePathForPID($0) }
        let parents: (Int32) -> Int32 = { LibprocProcessProbe.parentPIDForPID($0) }
        for tool in AgentTool.allCases where !tools.contains(tool) {
            cancelPending(tool)
        }
        if tools.contains(.claude) {
            handleSnapshot(tool: .claude, usage: claudeUsage, sessions: inputs.sessions,
                           processes: inputs.processes,
                           transcriptTail: { SessionMonitor.tailLines(forSessionID: $0) },
                           paths: paths, parents: parents)
        }
        guard tools.contains(.codex) else { return }
        handleSnapshot(tool: .codex, usage: inputs.codexLimits, sessions: inputs.sessions,
                       processes: inputs.codexProcesses,
                       transcriptTail: { SessionMonitor.tailLines(forSessionID: $0, tool: .codex) },
                       scannedAt: inputs.scannedAt, codexReached: inputs.codexReached,
                       paths: paths, parents: parents)
    }

    /// A hidden tool: drop its baseline and cancel its already-scheduled resumes.
    private func cancelPending(_ tool: AgentTool) {
        if states[tool] != nil { states[tool] = nil }
        epochs[tool, default: 0] += 1
    }
}
