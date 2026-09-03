@testable import ClaudeMeterCore
import Foundation
import Testing

/// The planner is the pure decision core of auto-resume: given a usage reading,
/// the armed set, live processes and transcript tails, it decides which sessions
/// to nudge *now* and carries a time-bounded retry window so a one-shot refill
/// keeps retrying until each armed session is actually eligible (or the window
/// closes). These tests pin that behavior without a GUI or real processes.
struct AutoResumePlannerTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)
    private let windowSeconds: Double = 300

    // Transcript tails.
    // JSONL fixture on one line, as in a real transcript.
    // swiftlint:disable line_length
    private let cutoff = #"{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"You've hit your session limit · resets 4:30am (Europe/Bratislava)"}]}}"#
    private let clean = #"{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"All done."}]}}"#
    // swiftlint:enable line_length

    private func session(_ id: String, path: String) -> SessionUsage {
        SessionUsage(id: id, origin: .cli, projectPath: path, models: ["m"],
                     tokens: TokenBreakdown(input: 0, output: 0, cacheCreation: 0, cacheRead: 0),
                     messageCount: 1, firstActivity: base, lastActivity: base, burnRate: 0,
                     running: .running)
    }

    private func proc(_ pid: Int32, cwd: String, tty: String? = "/dev/ttys001") -> LiveProcess {
        LiveProcess(pid: pid, cwd: cwd, tty: tty, ppid: 1)
    }

    private let iTerm: (Int32) -> String? = { _ in "/Applications/iTerm.app/Contents/MacOS/iTerm2" }
    private let terminalApp: (Int32) -> String? = { _ in
        "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
    }

    private let rootParent: (Int32) -> Int32 = { _ in 1 }

    private func plan(
        now: Date? = nil,
        previous: Double?,
        current: Double,
        window: ResumeWindow? = nil,
        lastRefillAt: Date? = nil,
        armed: Set<String>,
        sessions: [SessionUsage],
        processes: [LiveProcess],
        tail: @escaping (String) -> [String],
        exec: ((Int32) -> String?)? = nil,
    ) -> ResumePlan {
        AutoResumePlanner.plan(
            now: now ?? base,
            previousUtilization: previous,
            currentUtilization: current,
            window: window,
            windowSeconds: windowSeconds,
            lastRefillAt: lastRefillAt,
            armedIDs: armed,
            sessions: sessions,
            processes: processes,
            transcriptTail: tail,
            executablePath: exec ?? iTerm,
            parentPID: rootParent,
        )
    }

    // MARK: - Detection / window opening

    @Test func noRefillNoWindowDoesNothing() {
        let p = plan(previous: 50, current: 49, armed: ["s1"],
                     sessions: [session("s1", path: "/p1")],
                     processes: [proc(10, cwd: "/p1")], tail: { _ in [self.cutoff] })
        #expect(p.refillDetected == false)
        #expect(p.window == nil)
        #expect(p.targets.isEmpty)
    }

    @Test func refillOpensWindowAndFiresEligibleSession() {
        let p = plan(previous: 100, current: 0, armed: ["s1"],
                     sessions: [session("s1", path: "/p1")],
                     processes: [proc(10, cwd: "/p1", tty: "/dev/ttys003")],
                     tail: { _ in [self.cutoff] })
        #expect(p.refillDetected == true)
        #expect(p.window?.fired == ["s1"])
        #expect(p.targets.map(\.sessionID) == ["s1"])
        #expect(p.targets.first?.tty == "/dev/ttys003")
        #expect(p.targets.first?.pid == 10)
    }

    // A real 5h refill cannot happen twice within an hour; a second "drop" that
    // soon is a stale-vs-fresh usage reading flapping (e.g. cache served during
    // rate-limit backoff) and must NOT reopen the window — that caused repeated
    // resume attempts and notification storms.
    @Test func refillWithinCooldownOfPreviousIsIgnored() {
        let p = plan(now: base.addingTimeInterval(600), previous: 100, current: 0,
                     lastRefillAt: base, armed: ["s1"],
                     sessions: [session("s1", path: "/p1")],
                     processes: [proc(10, cwd: "/p1")], tail: { _ in [self.cutoff] })
        #expect(p.refillDetected == false)
        #expect(p.window == nil)
        #expect(p.targets.isEmpty)
    }

    @Test func refillAfterCooldownIsAccepted() {
        let p = plan(now: base.addingTimeInterval(3_700), previous: 100, current: 0,
                     lastRefillAt: base, armed: ["s1"],
                     sessions: [session("s1", path: "/p1")],
                     processes: [proc(10, cwd: "/p1")], tail: { _ in [self.cutoff] })
        #expect(p.refillDetected == true)
        #expect(p.targets.map(\.sessionID) == ["s1"])
    }

    // MARK: - The retry window (the core hardening)

    @Test func sessionNotYetEligibleRetriesOnLaterCycleWithinWindow() {
        // Cycle A: refill detected, but the session's tail isn't a limit cutoff yet.
        let a = plan(previous: 100, current: 0, armed: ["s1"],
                     sessions: [session("s1", path: "/p1")],
                     processes: [proc(10, cwd: "/p1")], tail: { _ in [self.clean] })
        #expect(a.targets.isEmpty)
        #expect(a.skipped.first?.reason == .notEligible("cleanlyFinished"))
        #expect(a.window != nil)

        // Cycle B: 10s later, no new refill, tail now shows the cutoff -> fires.
        let b = plan(now: base.addingTimeInterval(10), previous: 0, current: 0,
                     window: a.window, armed: ["s1"],
                     sessions: [session("s1", path: "/p1")],
                     processes: [proc(10, cwd: "/p1")], tail: { _ in [self.cutoff] })
        #expect(b.refillDetected == false)
        #expect(b.targets.map(\.sessionID) == ["s1"])
        #expect(b.window?.fired == ["s1"])
    }

    @Test func alreadyFiredSessionIsNotResumedAgain() {
        let window = ResumeWindow(deadline: base.addingTimeInterval(windowSeconds), fired: ["s1"])
        let p = plan(now: base.addingTimeInterval(10), previous: 0, current: 0,
                     window: window, armed: ["s1"],
                     sessions: [session("s1", path: "/p1")],
                     processes: [proc(10, cwd: "/p1")], tail: { _ in [self.cutoff] })
        #expect(p.targets.isEmpty)
        #expect(p.skipped.isEmpty)
        #expect(p.window?.fired == ["s1"])
    }

    @Test func expiredWindowClosesAndReportsUnfired() {
        let window = ResumeWindow(deadline: base, fired: [])
        let p = plan(now: base.addingTimeInterval(1), previous: 0, current: 0,
                     window: window, armed: ["s1"],
                     sessions: [session("s1", path: "/p1")],
                     processes: [proc(10, cwd: "/p1")], tail: { _ in [self.cutoff] })
        #expect(p.window == nil)
        #expect(p.windowExpired == true)
        #expect(p.targets.isEmpty)
    }

    @Test func expiredWindowWithEverythingFiredIsNotReportedAsMiss() {
        let window = ResumeWindow(deadline: base, fired: ["s1"])
        let p = plan(now: base.addingTimeInterval(1), previous: 0, current: 0,
                     window: window, armed: ["s1"],
                     sessions: [session("s1", path: "/p1")],
                     processes: [proc(10, cwd: "/p1")], tail: { _ in [self.cutoff] })
        #expect(p.window == nil)
        #expect(p.windowExpired == false)
    }

    // MARK: - Gates

    @Test func ambiguousCwdIsSkipped() {
        let p = plan(previous: 100, current: 0, armed: ["s1"],
                     sessions: [session("s1", path: "/p1")],
                     processes: [proc(10, cwd: "/p1"), proc(11, cwd: "/p1")],
                     tail: { _ in [self.cutoff] })
        #expect(p.targets.isEmpty)
        #expect(p.skipped.first?.reason == .noUniqueProcess)
    }

    @Test func nonDrivableTerminalIsSkipped() {
        let p = plan(previous: 100, current: 0, armed: ["s1"],
                     sessions: [session("s1", path: "/p1")],
                     processes: [proc(10, cwd: "/p1")], tail: { _ in [self.cutoff] },
                     exec: terminalApp)
        #expect(p.targets.isEmpty)
        #expect(p.skipped.first?.reason == .notDrivable("Terminal"))
    }

    @Test func unexpectedTTYIsSkipped() {
        let p = plan(previous: 100, current: 0, armed: ["s1"],
                     sessions: [session("s1", path: "/p1")],
                     processes: [proc(10, cwd: "/p1", tty: "/dev/null")],
                     tail: { _ in [self.cutoff] })
        #expect(p.skipped.first?.reason == .unexpectedTTY("/dev/null"))
    }

    @Test func unarmedSessionsAreIgnored() {
        let p = plan(previous: 100, current: 0, armed: [],
                     sessions: [session("s1", path: "/p1")],
                     processes: [proc(10, cwd: "/p1")], tail: { _ in [self.cutoff] })
        #expect(p.targets.isEmpty)
        #expect(p.skipped.isEmpty)
        #expect(p.window?.fired.isEmpty == true)
    }

    // An armed session whose own process is gone (tab closed, /clear, a fresh
    // `claude` started in the same folder) must never fire: the unique live
    // process in its cwd belongs to ANOTHER session, and `continue` would land
    // in that session's prompt.
    @Test func armedSessionNoLongerRunningIsSkipped() {
        let stale = session("s1", path: "/p1").withRunning(.idle)
        let p = plan(previous: 100, current: 0, armed: ["s1"],
                     sessions: [stale],
                     processes: [proc(10, cwd: "/p1")], tail: { _ in [self.cutoff] })
        #expect(p.targets.isEmpty)
        #expect(p.skipped.first?.reason == .notRunning)
        #expect(p.window?.fired.isEmpty == true)
    }
}
