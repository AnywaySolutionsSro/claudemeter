@testable import ClaudeMeterCore
import Testing

struct SparklineScaleTests {
    @Test func aLowFlatWeekIsZoomedIn() {
        #expect(SparklineScale.top(for: [10, 11]) == 15)
    }

    @Test func aHighWindowIsCappedAtAHundred() {
        #expect(SparklineScale.top(for: [90, 95]) == 100)
        #expect(SparklineScale.top(for: [100]) == 100)
        #expect(SparklineScale.top(for: [120]) == 100)
    }

    @Test func nothingUsedKeepsTheMinimumScale() {
        #expect(SparklineScale.top(for: [0, 0]) == 10)
        #expect(SparklineScale.top(for: []) == 10)
        #expect(SparklineScale.top(for: [2, 3]) == 10)
    }

    @Test func theTopIsARoundNumberWithHeadroom() {
        #expect(SparklineScale.top(for: [20, 40]) == 50) // 46 → 50
        #expect(SparklineScale.top(for: [60]) == 70) // 69 → 70
    }
}
