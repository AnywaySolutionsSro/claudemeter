@testable import ClaudeMeterCore
import Foundation
import Testing

struct UsageInsightsTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let reset = Date(timeIntervalSince1970: 1_800_010_000)

    private func sample(_ minutes: Double, _ used: Double) -> UsageSample {
        UsageSample(timestamp: t0.addingTimeInterval(minutes * 60), sessionUtilization: used,
                    sessionResetsAt: reset, weeklyUtilization: nil)
    }

    @Test func emptyHistoryHasNoInsights() {
        let insights = UsageInsights.compute(history: [], now: t0)
        #expect(insights.burn == nil)
        #expect(insights.paceRatio == nil)
        #expect(insights.trend.isEmpty)
        #expect(insights.history.isEmpty)
    }

    @Test func burnTrendAndPaceComeFromTheHistory() {
        let history = [sample(0, 10), sample(10, 12), sample(20, 14), sample(30, 30)]
        let insights = UsageInsights.compute(history: history, now: t0.addingTimeInterval(30 * 60))
        #expect(insights.burn == BurnRate.estimate(samples: history, now: t0.addingTimeInterval(30 * 60)))
        #expect(insights.burn?.isBurning == true)
        #expect(insights.trend == [10, 12, 14, 30])
        // Half an hour is no "usual pace" yet.
        #expect(insights.paceRatio == nil)
        #expect(insights.history == history)
    }

    private func weekly(_ hours: Double, _ used: Double) -> UsageSample {
        UsageSample(timestamp: t0.addingTimeInterval(hours * 3600), sessionUtilization: nil,
                    sessionResetsAt: nil, weeklyUtilization: used,
                    weeklyResetsAt: t0.addingTimeInterval(7 * 86400))
    }

    @Test func noPaceLineWithoutADayOfHistory() {
        let short = [weekly(0, 10), weekly(0.2, 10.5), weekly(0.4, 11)]
        #expect(!UsageInsights.hasPaceBaseline(short))
        #expect(UsageInsights.paceRatio(history: short,
                                        burn: BurnEstimate(percentPerHour: 3.7, etaToLimit: nil)) == nil)
        #expect(!UsageInsights.hasPaceBaseline([]))
    }

    @Test func aDayOfHistoryGivesAPaceRatio() throws {
        let long = [weekly(0, 1), weekly(10, 3), weekly(24, 5)]
        #expect(UsageInsights.hasPaceBaseline(long))
        let ratio = UsageInsights.paceRatio(history: long, burn: BurnEstimate(percentPerHour: 0.4, etaToLimit: nil))
        let typical = try #require(UsageStats.typicalPercentPerHour(samples: long))
        #expect(ratio == 0.4 / typical)
    }

    @Test func noPaceLineWithoutATypicalRate() {
        // A day long but flat: no typical rate to divide by.
        let flat = [weekly(0, 5), weekly(30, 5)]
        #expect(UsageInsights.hasPaceBaseline(flat))
        #expect(UsageInsights.paceRatio(history: flat,
                                        burn: BurnEstimate(percentPerHour: 1, etaToLimit: nil)) == nil)
    }
}
