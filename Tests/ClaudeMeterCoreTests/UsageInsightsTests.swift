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
        #expect(insights.paceRatio != nil)
        #expect(insights.history == history)
    }
}
