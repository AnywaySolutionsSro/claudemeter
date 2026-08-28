@testable import ClaudeMeterCore
import Testing

struct TextScaleTests {
    /// `NSFont.monospacedDigitSystemFont` line heights measured on macOS 26.
    /// Measured: 11→14, 13→16, 15→19, 17→20. The 12/14/16 rows are plausible
    /// fill-ins so the step-down path is exercised; the real values are supplied
    /// by AppKit at runtime, which is exactly why `textHeight` is injected.
    let heights: [Double: Double] = [
        11: 14, 12: 15, 13: 16, 14: 17, 15: 19, 16: 19, 17: 20,
    ]

    private func stubHeight(_ font: Double) -> Double {
        heights[font] ?? font + 3
    }

    /// The real menu bar: `NSStatusBar.system.thickness` is 22.0 and
    /// `MenuBarLabel.verticalPadding` is 2.
    private func metrics(_ scale: TextScale, thickness: Double = 22) -> (font: Double, padding: Double) {
        scale.menuBarMetrics(base: 11, padding: 2, thickness: thickness, textHeight: stubHeight)
    }

    @Test func multipliersAndTitles() {
        #expect(TextScale.standard.multiplier == 1.0)
        #expect(TextScale.large.multiplier == 1.15)
        #expect(TextScale.larger.multiplier == 1.3)
        #expect(TextScale.largest.multiplier == 1.5)
        #expect(TextScale.allCases.map(\.title) == ["Default", "Large", "Larger", "Largest"])
        #expect(TextScale.larger.id == "larger")
    }

    @Test func scaledRoundsToWholePointsHalfAwayFromZero() {
        #expect(TextScale.standard.scaled(11) == 11)
        #expect(TextScale.largest.scaled(11) == 17) // 16.5 rounds up
        #expect(TextScale.large.scaled(10) == 12) // 11.5 rounds up
        #expect(TextScale.larger.scaled(10) == 13) // 13.0 exactly
        #expect(TextScale.larger.scaled(11) == 14) // 14.3 rounds down
    }

    @Test func fromStoredFallsBackToStandard() {
        #expect(TextScale.fromStored(nil) == .standard)
        #expect(TextScale.fromStored("") == .standard)
        #expect(TextScale.fromStored("percentage") == .standard)
        #expect(TextScale.fromStored("larger") == .larger)
    }

    @Test func menuBarMetricsAtEachScale() {
        #expect(metrics(.standard).font == 11)
        #expect(metrics(.standard).padding == 2)

        #expect(metrics(.large).font == 13)
        #expect(metrics(.large).padding == 2)

        #expect(metrics(.larger).font == 14)
        #expect(metrics(.larger).padding == 2)

        // 17pt needs the compressed padding: 20 + 2*2 = 24 overflows, 20 + 2*1 = 22 fits.
        #expect(metrics(.largest).font == 17)
        #expect(metrics(.largest).padding == 1)
    }

    @Test func paddingCompressesOnlyWhenItBuysAStep() {
        // Every scale whose font already fits at the preferred padding keeps it.
        for scale in [TextScale.standard, .large, .larger] {
            #expect(metrics(scale).padding == 2)
        }
    }

    @Test func menuBarFontIsMonotonicInScale() throws {
        let fonts = TextScale.allCases.map { metrics($0).font }
        #expect(fonts == fonts.sorted())
        // Sortedness alone also holds if every scale collapsed to the base font,
        // so assert the ladder actually climbs.
        #expect(try #require(fonts.first) < fonts.last!)
    }

    @Test func neverReturnsBelowBaseEvenWhenNothingFits() {
        // Degenerate thickness: not even (11, 1) fits. The base floor wins over
        // fitting the bar, because base is today's unconditional behaviour.
        let result = metrics(.largest, thickness: 10)
        #expect(result.font == 11)
        #expect(result.padding == 2)
    }
}
