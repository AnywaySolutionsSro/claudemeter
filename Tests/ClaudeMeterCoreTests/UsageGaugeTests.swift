import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct UsageGaugeTests {
    private func bucket(_ utilization: Double) -> UsageBucket {
        UsageBucket(utilization: utilization, resetsAt: Date(timeIntervalSince1970: 1_000), status: nil)
    }

    @Test func percentLeftIsRemainder() {
        let g = UsageGauge(label: "Session", percentLeft: 22, resetsAt: nil)
        #expect(g.percentLeft == 22)
    }

    @Test func percentLeftIsClamped() {
        #expect(UsageGauge(label: "x", percentLeft: 140, resetsAt: nil).percentLeft == 100)
        #expect(UsageGauge(label: "x", percentLeft: -5, resetsAt: nil).percentLeft == 0)
    }

    @Test func gaugesMapPresentBucketsInOrderWithShortLabels() {
        let snap = UsageSnapshot(
            fiveHour: bucket(22), sevenDay: bucket(63),
            sevenDayOpus: nil, sevenDaySonnet: bucket(23),
            fetchedAt: Date())
        let gauges = snap.gauges
        #expect(gauges.map(\.label) == ["Session", "Weekly", "Sonnet"])
        // utilization 22 -> 78% left, 63 -> 37% left, 23 -> 77% left
        #expect(gauges.map { Int($0.percentLeft) } == [78, 37, 77])
    }

    @Test func gaugesOmitsAbsentBuckets() {
        let snap = UsageSnapshot(fiveHour: bucket(10), sevenDay: nil,
                                 sevenDayOpus: nil, sevenDaySonnet: nil, fetchedAt: Date())
        #expect(snap.gauges.map(\.label) == ["Session"])
    }
}
