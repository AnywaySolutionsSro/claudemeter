@testable import ClaudeMeterCore
import Foundation
import Testing

struct LimitEventsTests {
    private let now = Date(timeIntervalSince1970: 1_796_000_000)
    private var resets: Date { now.addingTimeInterval(3600) }

    private func snap(session: Double? = nil, weekly: Double? = nil, resetsAt: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: session.map { UsageBucket(utilization: $0, resetsAt: resetsAt) },
            sevenDay: weekly.map { UsageBucket(utilization: $0, resetsAt: resetsAt) },
            sevenDayOpus: nil, sevenDaySonnet: nil, fetchedAt: now,
        )
    }

    @Test func testDetectMatchesLegacyBehaviour() {
        // First reading seeds silently.
        #expect(LimitEvents.detect(previous: nil, current: snap(session: 95), now: now).isEmpty)
        // No movement, no events.
        #expect(LimitEvents.detect(previous: snap(session: 50), current: snap(session: 55), now: now).isEmpty)
        // Highest crossing only, with the ETA to reset.
        let crossed = LimitEvents.detect(
            previous: snap(session: 70, resetsAt: resets),
            current: snap(session: 95, resetsAt: resets),
            now: now,
        )
        #expect(crossed.count == 1)
        guard case let .crossed(threshold, window, eta) = crossed[0] else { Issue.record("expected crossing"); return }
        #expect(threshold == 90)
        #expect(window.id == "Session")
        #expect(eta == 3600)
        // Refill: a drop of >= 25 emits one reset, preferring weekly.
        let reset = LimitEvents.detect(
            previous: snap(session: 80, weekly: 80),
            current: snap(session: 0, weekly: 0),
            now: now,
        )
        #expect(reset.count == 1)
        guard case let .reset(refilled) = reset[0] else { Issue.record("expected reset"); return }
        #expect(refilled.kind == .weekly)
        // Two windows crossing in one poll yield two events.
        let both = LimitEvents.detect(
            previous: snap(session: 70, weekly: 70),
            current: snap(session: 85, weekly: 100),
            now: now,
        )
        #expect(both.count == 2)
        // A window with no prior reading crossed nothing.
        #expect(LimitEvents.detect(previous: snap(weekly: 10), current: snap(session: 99, weekly: 10), now: now)
            .isEmpty)
    }

    @Test func testStalePassedResetDoesNotCrossThreshold() {
        // Codex reports a window whose reset passed as 0% used.
        let passed = CodexWindowReading(usedPercent: 97, windowMinutes: 10080, resetsAt: now.addingTimeInterval(-60))
        let reading = CodexLimitReading(
            limitID: "codex",
            observedAt: now.addingTimeInterval(-86400 * 3),
            windows: [passed],
            reachedType: nil,
        )
        let stale = CodexLimits.snapshot(from: reading, now: now)
        #expect(stale.sevenDay?.utilization == 0)
        // Seeded from the stale reading, a later identical one fires nothing.
        #expect(LimitEvents.detect(previous: stale, current: stale, now: now).isEmpty)
        // Going from a live 70% to the stale-as-full reading is a refill, never a crossing.
        let events = LimitEvents.detect(previous: snap(weekly: 70), current: stale, now: now)
        #expect(events.allSatisfy {
            if case .crossed = $0 {
                false
            } else {
                true
            }
        })
    }

    @Test func testNotificationIDsAreNamespacedByTool() {
        let weekly = LimitWindow(kind: .weekly, label: "Weekly", bucket: UsageBucket(utilization: 80, resetsAt: nil))
        let claude = NotificationIDs.threshold(tool: .claude, window: weekly, threshold: 90)
        let codex = NotificationIDs.threshold(tool: .codex, window: weekly, threshold: 90)
        #expect(claude == "claude-threshold-Weekly-90")
        #expect(codex == "codex-threshold-Weekly-90")
        #expect(NotificationIDs.resetReminder(tool: .claude) != NotificationIDs.resetReminder(tool: .codex))
        #expect(NotificationIDs.resetReminder(tool: .codex) == "codex-reset-reminder")
        #expect(NotificationIDs.refill(tool: .codex, unique: "x") == "codex-refill-x")
        #expect(NotificationIDs.title("Heads up", tool: .claude) == "Claude · Heads up")
        #expect(NotificationIDs.title("Heads up", tool: .codex) == "Codex · Heads up")
    }
}
