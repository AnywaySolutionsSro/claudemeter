@testable import ClaudeMeterCore
import Foundation
import Testing

struct CodexDisplayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")

    private func session(_ id: String, tool: AgentTool?, running: RunningState = .running) -> SessionUsage {
        SessionUsage(id: id, origin: .cli, projectPath: "/code/\(id)", models: [],
                     tokens: TokenBreakdown(input: 1), messageCount: 1,
                     firstActivity: now, lastActivity: now, burnRate: 0, running: running, tool: tool)
    }

    // MARK: Past-reset note

    @Test func staleNoteOnlyOnceTheResetHasPassed() {
        let upcoming = UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(60))
        let unknown = UsageBucket(utilization: 0, resetsAt: nil)
        #expect(CodexDisplay
            .staleResetNote(upcoming, now: now, style: .twentyFour, timeZone: utc, locale: posix) == nil)
        #expect(CodexDisplay.staleResetNote(unknown, now: now, style: .twentyFour, timeZone: utc, locale: posix) == nil)
    }

    @Test func staleNoteSameDayShowsTheClockTime() {
        // 1_800_000_000 is 2027-01-15 08:00 UTC; the reset was an hour earlier.
        let passed = UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(-3600))
        #expect(CodexDisplay.staleResetNote(passed, now: now, style: .twentyFour, timeZone: utc, locale: posix)
            == "reset at 07:00 · no reading since")
    }

    @Test func staleNoteEarlierDayShowsTheDate() {
        let passed = UsageBucket(utilization: 0, resetsAt: now.addingTimeInterval(-2 * 86400))
        #expect(CodexDisplay.staleResetNote(passed, now: now, style: .twentyFour, timeZone: utc, locale: posix)
            == "reset at 13 Jan 08:00 · no reading since")
    }

    // MARK: Activity line

    @Test func activityCountsOnlyCodexSessions() {
        let sessions = [
            session("a", tool: .codex), session("b", tool: .codex),
            session("c", tool: .codex, running: .idle), session("d", tool: nil), session("e", tool: .claude),
        ]
        let line = CodexDisplay.activityLine(sessions: sessions, armedIDs: ["a", "c", "d"])
        #expect(line == "2 running · 2 armed")
    }

    @Test func activityWithNothingGoingOn() {
        #expect(CodexDisplay.activityLine(sessions: [], armedIDs: []) == "0 running · 0 armed")
    }

    // MARK: Widget rings

    private func gauge(_ label: String, _ left: Double = 50) -> UsageGauge {
        UsageGauge(label: label, percentLeft: left, resetsAt: nil)
    }

    private func snapshot(claude: [UsageGauge], codex: [UsageGauge]?,
                          sessions: [SessionUsage] = []) -> SessionSnapshot {
        SessionSnapshot(generatedAt: now, sessions: sessions, totalTokens: 0, runningCount: 0,
                        usageGauges: claude, codexGauges: codex)
    }

    @Test func ringsWithoutCodexAreClaudesFirstFour() {
        let snap = snapshot(claude: ["Session", "Weekly", "Opus", "Sonnet", "Haiku"].map { gauge($0) }, codex: nil)
        let rings = snap.ringGauges(limit: 4)
        #expect(rings.map(\.gauge.label) == ["Session", "Weekly", "Opus", "Sonnet"])
        #expect(rings.allSatisfy { $0.tool == .claude })
    }

    @Test func ringsKeepBothWeeklyWindowsApartAndClaudeFirst() {
        let snap = snapshot(claude: [gauge("Session", 10), gauge("Weekly", 20), gauge("Sonnet")],
                            codex: [gauge("Session", 80), gauge("Weekly", 90)])
        let rings = snap.ringGauges(limit: 4)
        #expect(rings.map(\.tool) == [.claude, .claude, .codex, .codex])
        #expect(rings.map(\.gauge.percentLeft) == [10, 20, 80, 90])
        #expect(Set(rings.map(\.id)).count == 4)
    }

    @Test func ringsGiveClaudeAtLeastTwoSlots() {
        let snap = snapshot(claude: [gauge("Session"), gauge("Weekly")],
                            codex: [gauge("Session"), gauge("Weekly"), gauge("Other")])
        #expect(snap.ringGauges(limit: 4).map(\.tool) == [.claude, .claude, .codex, .codex])
    }

    @Test func ringsWithFewClaudeWindowsLetCodexFill() {
        let snap = snapshot(claude: [gauge("Weekly")], codex: [gauge("Session"), gauge("Weekly")])
        #expect(snap.ringGauges(limit: 4).map(\.tool) == [.claude, .codex, .codex])
    }

    @Test func includesCodexFromGaugesOrSessions() {
        #expect(!snapshot(claude: [], codex: nil, sessions: [session("x", tool: nil)]).includesCodex)
        #expect(snapshot(claude: [], codex: []).includesCodex)
        #expect(snapshot(claude: [], codex: nil, sessions: [session("x", tool: .codex)]).includesCodex)
    }

    // MARK: Widget reading age

    @Test func readingAgeShowsOnlyWhenOlderThanAnHour() {
        func note(_ age: TimeInterval?) -> String? {
            CodexDisplay.readingAgeNote(
                asOf: age.map { now.addingTimeInterval(-$0) }, now: now, style: .twentyFour,
                timeZone: utc, locale: posix,
            )
        }
        #expect(note(nil) == nil)
        #expect(note(30 * 60) == nil)
        #expect(note(3600) == nil)
        // now = 2027-01-15 08:00 UTC
        #expect(note(2 * 3600) == "as of 06:00")
        #expect(note(10 * 3600) == "as of 14 Jan 22:00")
    }

    @Test func readingAgeFollowsTheClockStyle() {
        let note = CodexDisplay.readingAgeNote(
            asOf: now.addingTimeInterval(-2 * 3600), now: now, style: .twelve, timeZone: utc, locale: posix,
        )
        #expect(note == "as of 6:00 AM")
    }
}
