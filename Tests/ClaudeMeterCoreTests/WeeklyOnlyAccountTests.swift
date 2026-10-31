@testable import ClaudeMeterCore
import Foundation
import Testing

/// Verified Ultra accounts report `five_hour: null`. Everything that used to hang off
/// the session window has to keep working from the weekly one, and the two must never
/// be compared with each other: the rollout flips accounts between shapes mid-run.
struct WeeklyOnlyAccountTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 7 * 24 * 3600

    private func bucket(_ utilization: Double, resetsIn: TimeInterval = 3600) -> UsageBucket {
        UsageBucket(utilization: utilization, resetsAt: now.addingTimeInterval(resetsIn))
    }

    private func snapshot(
        session: UsageBucket? = nil,
        weekly: UsageBucket? = nil,
        fable: UsageBucket? = nil,
    ) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: session, sevenDay: weekly, sevenDayOpus: nil, sevenDaySonnet: nil,
            modelWeekly: fable.map { [ModelWeeklyLimit(label: "Fable", bucket: $0, isActive: false)] } ?? [],
            fetchedAt: now,
        )
    }

    // MARK: - Windows

    @Test func windowsListEveryLimitInDisplayOrder() {
        let snap = snapshot(session: bucket(1), weekly: bucket(2), fable: bucket(3))
        #expect(snap.limitWindows.map(\.label) == ["Session", "Weekly", "Fable"])
        #expect(snap.limitWindows.map(\.kind) == [.session, .weekly, .model])
    }

    @Test func gaugesMatchWindows() {
        let snap = snapshot(weekly: bucket(40), fable: bucket(10))
        #expect(snap.gauges.map(\.label) == ["Weekly", "Fable"])
        #expect(snap.gauges.map(\.percentLeft) == [60, 90])
    }

    @Test func windowsDescribeThemselves() {
        let snap = snapshot(session: bucket(1), weekly: bucket(2), fable: bucket(3))
        #expect(snap.limitWindows.map(\.phrase) == ["session window", "weekly limit", "Fable weekly limit"])
        #expect(snap.limitWindows.map(\.budgetName) == ["session", "weekly", "Fable"])
    }

    // MARK: - Blocking window

    @Test func noBlockingWindowWhileUsageRemains() {
        #expect(snapshot(session: bucket(99), weekly: bucket(99)).blockingWindow == nil)
    }

    @Test func exhaustedWeeklyBlocksWithoutASessionWindow() {
        #expect(snapshot(weekly: bucket(100)).blockingWindow?.kind == .weekly)
    }

    @Test func exhaustedWeeklyBlocksEvenWhenSessionHasRoom() {
        #expect(snapshot(session: bucket(10), weekly: bucket(100)).blockingWindow?.kind == .weekly)
    }

    @Test func blockingWindowIsTheLastToReset() {
        let snap = snapshot(session: bucket(100, resetsIn: 3600), weekly: bucket(100, resetsIn: week / 2))
        #expect(snap.blockingWindow?.kind == .weekly)
    }

    @Test func anExhaustedModelWindowDoesNotBlockTheAccount() {
        #expect(snapshot(weekly: bucket(40), fable: bucket(100)).blockingWindow == nil)
    }

    // MARK: - Refill detection

    @Test func weeklyResetIsARefill() {
        let refilled = UsageStats.refilledWindows(
            previous: snapshot(weekly: bucket(100)).limitWindows,
            current: snapshot(weekly: bucket(0)).limitWindows,
        )
        #expect(refilled.map(\.kind) == [.weekly])
    }

    @Test func modelWindowResetIsARefill() {
        let refilled = UsageStats.refilledWindows(
            previous: snapshot(weekly: bucket(50), fable: bucket(100)).limitWindows,
            current: snapshot(weekly: bucket(50), fable: bucket(0)).limitWindows,
        )
        #expect(refilled.map(\.label) == ["Fable"])
    }

    /// The temporary limit being lifted mid-run: 80% session → 30% weekly is two
    /// different windows, not a 50-point drop.
    @Test func sessionDisappearingIsNotARefill() {
        let refilled = UsageStats.refilledWindows(
            previous: snapshot(session: bucket(80), weekly: bucket(30)).limitWindows,
            current: snapshot(weekly: bucket(30)).limitWindows,
        )
        #expect(refilled.isEmpty)
    }

    // MARK: - Threshold crossings

    @Test func weeklyCrossingReportsOnlyTheHighestThreshold() {
        let crossings = UsageStats.crossedWindows(
            previous: snapshot(weekly: bucket(70)).limitWindows,
            current: snapshot(weekly: bucket(95)).limitWindows,
            thresholds: [80, 90, 100],
        )
        #expect(crossings.map(\.threshold) == [90])
        #expect(crossings.map(\.window.kind) == [.weekly])
    }

    @Test func eachWindowCrossesIndependently() {
        let crossings = UsageStats.crossedWindows(
            previous: snapshot(session: bucket(70), weekly: bucket(85)).limitWindows,
            current: snapshot(session: bucket(81), weekly: bucket(91)).limitWindows,
            thresholds: [80, 90, 100],
        )
        #expect(crossings.map(\.window.kind) == [.session, .weekly])
        #expect(crossings.map(\.threshold) == [80, 90])
    }

    /// A window that just appeared has no prior reading, so nothing was crossed.
    @Test func aNewlyAppearedWindowCrossesNothing() {
        let crossings = UsageStats.crossedWindows(
            previous: snapshot(weekly: bucket(30)).limitWindows,
            current: snapshot(session: bucket(95), weekly: bucket(30)).limitWindows,
            thresholds: [80, 90, 100],
        )
        #expect(crossings.isEmpty)
    }

    // MARK: - Auto-resume gate

    @Test func gateOpensOnWeeklyResetWithoutASessionWindow() {
        let gate = AutoResumePlanner.gate(
            previous: snapshot(weekly: bucket(100)).limitWindows,
            current: snapshot(weekly: bucket(0)),
        )
        #expect(gate == .clear(refilled: snapshot(weekly: bucket(0)).limitWindows))
    }

    /// A Max cutoff at the weekly limit with a low session: the session barely drops
    /// at the weekly reset, so only the weekly window can open the resume window.
    @Test func gateOpensOnWeeklyResetWhenSessionDroppedLittle() {
        let after = snapshot(session: bucket(0), weekly: bucket(0))
        let gate = AutoResumePlanner.gate(
            previous: snapshot(session: bucket(20), weekly: bucket(100)).limitWindows,
            current: after,
        )
        #expect(gate == .clear(refilled: [after.limitWindows[1]]))
    }

    @Test func sessionRefillUnderAnExhaustedWeeklyStaysBlocked() {
        let after = snapshot(session: bucket(0), weekly: bucket(100))
        let gate = AutoResumePlanner.gate(
            previous: snapshot(session: bucket(100), weekly: bucket(100)).limitWindows,
            current: after,
        )
        #expect(gate == .blocked(after.limitWindows[1]))
    }

    /// Wording copied from a real transcript; `limit` must keep matching it.
    @Test func aWeeklyCutoffIsEligible() {
        let line = """
        {"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","role":"assistant",\
        "stop_reason":"stop_sequence","content":[{"type":"text",\
        "text":"You've hit your weekly limit · resets 6am (Europe/Zagreb)"}]}}
        """
        #expect(CutoffDetector().classify(tailLines: [line], isRunning: false) == .eligibleCutoff)
    }

    // MARK: - History

    @Test func sampleIsTakenWithoutASessionWindow() throws {
        let sample = try #require(snapshot(weekly: bucket(40, resetsIn: week)).sample(at: now))
        #expect(sample.sessionUtilization == nil)
        #expect(sample.trackedUtilization == 40)
        #expect(sample.weeklyResetsAt == now.addingTimeInterval(week))
    }

    @Test func noSampleWithoutAnyAccountWindow() {
        #expect(snapshot(fable: bucket(40)).sample(at: now) == nil)
    }

    /// `history.json` written by earlier versions has no `weeklyResetsAt`; a decode
    /// failure there silently drops the whole file.
    @Test func historyFromEarlierVersionsStillDecodes() throws {
        let json = """
        [{"timestamp":1793265303.7,"sessionUtilization":6,"sessionResetsAt":1793281200,"weeklyUtilization":88}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let samples = try decoder.decode([UsageSample].self, from: Data(json.utf8))
        #expect(samples.first?.sessionUtilization == 6)
        #expect(samples.first?.weeklyResetsAt == nil)
    }

    private func weeklySample(minutes: Double, _ utilization: Double, resetsAt: Date? = nil) -> UsageSample {
        UsageSample(
            timestamp: now.addingTimeInterval(minutes * 60), sessionUtilization: nil, sessionResetsAt: nil,
            weeklyUtilization: utilization, weeklyResetsAt: resetsAt ?? now.addingTimeInterval(week),
        )
    }

    @Test func burnRateRunsOnTheWeeklyWindow() throws {
        let samples = [weeklySample(minutes: 0, 10), weeklySample(minutes: 30, 12)]
        let estimate = try #require(BurnRate.estimate(samples: samples, now: now.addingTimeInterval(1800)))
        #expect(abs(estimate.percentPerHour - 4) < 0.001)
    }

    /// The weekly `resets_at` carries sub-second noise; that must not split a window.
    @Test func smallResetJitterKeepsTheWeeklyWindow() {
        let reset = now.addingTimeInterval(week)
        let a = weeklySample(minutes: 0, 10, resetsAt: reset)
        let b = weeklySample(minutes: 30, 12, resetsAt: reset.addingTimeInterval(1.5))
        #expect(a.isSameWindow(as: b))
    }

    @Test func aNewWeekIsANewWindow() {
        let a = weeklySample(minutes: 0, 90)
        let b = weeklySample(minutes: 30, 0, resetsAt: now.addingTimeInterval(2 * week))
        #expect(!a.isSameWindow(as: b))
    }

    @Test func sessionAndWeeklySamplesNeverShareAWindow() {
        let session = UsageSample(
            timestamp: now, sessionUtilization: 80, sessionResetsAt: now, weeklyUtilization: 30,
        )
        #expect(!session.isSameWindow(as: weeklySample(minutes: 5, 30)))
    }

    @Test func typicalPaceIgnoresTheOldSessionRates() {
        let session = (0 ..< 4).map { index in
            UsageSample(
                timestamp: now.addingTimeInterval(Double(index) * 3600), sessionUtilization: Double(index) * 30,
                sessionResetsAt: now, weeklyUtilization: nil,
            )
        }
        let weekly = [weeklySample(minutes: 600, 10), weeklySample(minutes: 660, 12)]
        #expect(UsageStats.typicalPercentPerHour(samples: session + weekly) == 2)
    }

    @Test func trendFollowsTheCurrentWindowOnly() {
        let samples = [
            weeklySample(minutes: 10, 90, resetsAt: now),
            weeklySample(minutes: 20, 1),
            weeklySample(minutes: 30, 3),
        ]
        #expect(UsageStats.currentWindowTrend(samples: samples) == [1, 3])
    }

    // MARK: - Weekly pace

    @Test func noPaceVerdictInTheFirstHoursOfTheWeek() {
        #expect(WeeklyPace.estimate(bucket(5, resetsIn: week - 3600), now: now) == nil)
    }

    @Test func noPaceWithoutAResetDate() {
        #expect(WeeklyPace.estimate(UsageBucket(utilization: 50, resetsAt: nil), now: now) == nil)
    }

    @Test func noPaceOnceExhausted() {
        #expect(WeeklyPace.estimate(bucket(100, resetsIn: week / 2), now: now) == nil)
    }

    @Test func onTrackWhenUsageMatchesTheElapsedWeek() throws {
        let pace = try #require(WeeklyPace.estimate(bucket(48, resetsIn: week / 2), now: now))
        #expect(abs(pace.expectedPercent - 50) < 0.001)
        #expect(pace.runsOutIn == nil)
    }

    @Test func runsOutEarlyWhenWellAheadOfTheWeek() throws {
        // 80% used in 3.5 days: 20% left at ~22.9%/day is about 21 hours.
        let pace = try #require(WeeklyPace.estimate(bucket(80, resetsIn: week / 2), now: now))
        #expect(abs((pace.runsOutIn ?? 0) - 21 * 3600) < 1)
    }
}
