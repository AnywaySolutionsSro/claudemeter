@testable import ClaudeMeterCore
import Foundation
import Testing

struct BatteryPillTests {
    /// Round numbers so every expected rect is easy to check by hand: the outline plus
    /// its inset is 2 pt per side, one cell is 30 + 2 × 4 = 38 pt wide.
    private let metrics = BatteryMetrics(
        height: 18, cellTextWidth: 30, cellPadding: 4, lineWidth: 1, inset: 1,
        cornerRadius: 4, dividerWidth: 1, nubGap: 1, nubWidth: 2, nubHeightRatio: 0.5,
    )

    // MARK: - Figures

    @Test func levelIsTheShareLeftClampedAndEmptyWithoutAReading() {
        #expect(BatteryPill.level(percentLeft: 68) == 0.68)
        #expect(BatteryPill.level(percentLeft: 140) == 1)
        #expect(BatteryPill.level(percentLeft: -5) == 0)
        #expect(BatteryPill.level(percentLeft: nil) == 0)
    }

    @Test func figuresAreRoundedPercentsOrADashNeverAFakeZero() {
        #expect(BatteryPill.figure(percentLeft: 67.6) == "68%")
        #expect(BatteryPill.figure(percentLeft: 0) == "0%")
        #expect(BatteryPill.figure(percentLeft: nil) == "—")
        #expect(BatteryPill.references.contains("100%"))
        #expect(BatteryPill.references.contains("—"))
    }

    // MARK: - Claude only

    @Test func singleBodyIsOneCellWideWithTheNubOnTheRight() {
        let layout = BatteryPill.single(claudeLeft: 68, metrics: metrics)
        #expect(layout.body == PillRect(x: 0, y: 0, width: 42, height: 18))
        #expect(layout.inner == PillRect(x: 2, y: 2, width: 38, height: 14))
        #expect(layout.innerRadius == 2)
        #expect(layout.divider == nil)
        // Nub: a point clear of the body, half its height, centred vertically.
        #expect(layout.nub == PillRect(x: 43, y: 4.5, width: 2, height: 9))
        #expect(layout.width == 45)
        #expect(layout.height == 18)
    }

    @Test func singleFillStartsAtTheLeftAndDrainsFromTheRight() throws {
        let cell = try #require(BatteryPill.single(claudeLeft: 68, metrics: metrics).cells.first)
        #expect(cell.tool == .claude)
        #expect(cell.text == "68%")
        #expect(cell.area == PillRect(x: 2, y: 2, width: 38, height: 14))
        #expect(cell.fill.x == 2)
        #expect(abs(cell.fill.width - 0.68 * 38) < 1e-9)
        #expect(cell.fill.y == 2)
        #expect(cell.fill.height == 14)
    }

    @Test func singleFullAndEmptyFills() throws {
        let full = try #require(BatteryPill.single(claudeLeft: 100, metrics: metrics).cells.first)
        #expect(full.fill == full.area)
        let missing = try #require(BatteryPill.single(claudeLeft: nil, metrics: metrics).cells.first)
        #expect(missing.fill.width == 0)
        #expect(missing.text == "—")
    }

    // MARK: - Claude and Codex

    @Test func dualBodyHoldsTwoCellsAndADividerInTheMiddle() throws {
        let layout = BatteryPill.dual(claudeLeft: 68, codexLeft: 40, metrics: metrics)
        // 2 + 38 + 1 + 38 + 2
        #expect(layout.body == PillRect(x: 0, y: 0, width: 81, height: 18))
        let divider = try #require(layout.divider)
        #expect(divider == PillRect(x: 40, y: 1, width: 1, height: 16))
        #expect(layout.body.midX == divider.midX)
        #expect(layout.nub == PillRect(x: 82, y: 4.5, width: 2, height: 9))
        #expect(layout.width == 84)
        #expect(layout.cells.map(\.tool) == [.claude, .codex])
        #expect(layout.cells.map(\.area) == [
            PillRect(x: 2, y: 2, width: 38, height: 14),
            PillRect(x: 41, y: 2, width: 38, height: 14),
        ])
    }

    @Test func claudeFillIsAnchoredAtTheDividerAndDrainsFromTheLeftEdge() throws {
        let layout = BatteryPill.dual(claudeLeft: 68, codexLeft: 40, metrics: metrics)
        let divider = try #require(layout.divider)
        let claude = layout.cells[0]
        #expect(claude.text == "68%")
        #expect(abs(claude.fill.maxX - divider.x) < 1e-9)
        #expect(abs(claude.fill.width - 0.68 * 38) < 1e-9)
    }

    @Test func codexFillIsAnchoredAtTheDividerAndDrainsFromTheRightEdge() throws {
        let layout = BatteryPill.dual(claudeLeft: 68, codexLeft: 40, metrics: metrics)
        let divider = try #require(layout.divider)
        let codex = layout.cells[1]
        #expect(codex.text == "40%")
        #expect(codex.fill.x == divider.maxX)
        #expect(abs(codex.fill.width - 0.40 * 38) < 1e-9)
    }

    @Test func aMissingHalfIsAnEmptyTrackWithADash() {
        let layout = BatteryPill.dual(claudeLeft: nil, codexLeft: 100, metrics: metrics)
        #expect(layout.cells[0].fill.width == 0)
        #expect(layout.cells[0].text == "—")
        #expect(layout.cells[1].fill == layout.cells[1].area)
    }

    @Test func widthDependsOnlyOnTheMetricsNeverOnTheReading() {
        let readings: [Double?] = [nil, 0, 5, 68, 100]
        let singles = Set(readings.map { BatteryPill.single(claudeLeft: $0, metrics: metrics).width })
        let duals = Set(readings.map { BatteryPill.dual(claudeLeft: $0, codexLeft: $0, metrics: metrics).width })
        #expect(singles.count == 1)
        #expect(duals.count == 1)
    }

    // MARK: - Text

    @Test func textIsCentredInItsCell() {
        let cell = PillRect(x: 41, y: 2, width: 38, height: 14)
        let origin = BatteryPill.textOrigin(textWidth: 20, textHeight: 10, in: cell)
        #expect(origin.x == 50)
        #expect(origin.y == 4)
    }

    @Test func degenerateMetricsNeverProduceNegativeSizes() {
        let tiny = BatteryMetrics(
            height: 2, cellTextWidth: 0, cellPadding: 0, lineWidth: 1, inset: 1,
            cornerRadius: 0, dividerWidth: 1, nubGap: 0, nubWidth: 1, nubHeightRatio: 0.5,
        )
        let layout = BatteryPill.dual(claudeLeft: 50, codexLeft: 50, metrics: tiny)
        #expect(layout.inner.height == 0)
        #expect(layout.innerRadius == 0)
        #expect(layout.cells.allSatisfy { $0.fill.width >= 0 && $0.area.width >= 0 })
    }
}
