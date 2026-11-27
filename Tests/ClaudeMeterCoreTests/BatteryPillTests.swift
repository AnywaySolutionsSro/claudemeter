@testable import ClaudeMeterCore
import Foundation
import Testing

struct BatteryPillTests {
    /// Round numbers so every expected rect is easy to check by hand: the outline plus
    /// its inset is 2 pt per side, one cell is 30 + 2 × 4 = 38 pt wide.
    private let metrics = BatteryMetrics(
        height: 18, cellTextWidth: 30, cellPadding: 4, lineWidth: 1, inset: 1,
        cornerRadius: 4, dividerWidth: 1,
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
        #expect(BatteryPill.minimumFigure == "00%")
    }

    // MARK: - Width follows the figures

    /// 10 pt per character, so "5%" is 20 (below the 30 minimum), "89%" 30, "100%" 40.
    private let measure: (String) -> Double = { Double($0.count) * 10 }

    @Test func aShortFigureGetsTheMinimumCellAndALongOneGrows() {
        let short = BatteryPill.single(left: 5, metrics: metrics, measure: measure)
        let mid = BatteryPill.single(left: 89, metrics: metrics, measure: measure)
        let full = BatteryPill.single(left: 100, metrics: metrics, measure: measure)
        #expect(short.width == mid.width)
        #expect(short.cells[0].area.width == 38)
        #expect(full.cells[0].area.width == 48)
        #expect(full.width == short.width + 10)
    }

    @Test func dualWidthIsTheSumOfItsCellsAndDivider() {
        let layout = BatteryPill.dual(claudeLeft: 5, codexLeft: 100, metrics: metrics, measure: measure)
        #expect(layout.cells[0].area.width == 38)
        #expect(layout.cells[1].area.width == 48)
        // 2 + 38 + 1 + 48 + 2
        #expect(layout.width == 91)
        #expect(layout.divider?.x == 40)
        let narrow = BatteryPill.dual(claudeLeft: 5, codexLeft: 89, metrics: metrics, measure: measure)
        #expect(narrow.width < layout.width)
    }

    @Test func fillsStayProportionalToTheirOwnCell() {
        let layout = BatteryPill.dual(claudeLeft: 50, codexLeft: 100, metrics: metrics, measure: measure)
        #expect(layout.cells[0].fill.width == 19)
        #expect(layout.cells[1].fill.width == 48)
    }

    // MARK: - Claude only

    @Test func singleBodyIsOneCellWide() {
        let layout = BatteryPill.single(left: 68, metrics: metrics)
        #expect(layout.body == PillRect(x: 0, y: 0, width: 42, height: 18))
        #expect(layout.inner == PillRect(x: 2, y: 2, width: 38, height: 14))
        #expect(layout.innerRadius == 2)
        #expect(layout.divider == nil)
        #expect(layout.width == 42)
        #expect(layout.height == 18)
    }

    @Test func singleFillStartsAtTheLeftAndDrainsFromTheRight() throws {
        let cell = try #require(BatteryPill.single(left: 68, metrics: metrics).cells.first)
        #expect(cell.tool == .claude)
        #expect(cell.text == "68%")
        #expect(cell.area == PillRect(x: 2, y: 2, width: 38, height: 14))
        #expect(cell.fill.x == 2)
        #expect(abs(cell.fill.width - 0.68 * 38) < 1e-9)
        #expect(cell.fill.y == 2)
        #expect(cell.fill.height == 14)
    }

    @Test func singleFullAndEmptyFills() throws {
        let full = try #require(BatteryPill.single(left: 100, metrics: metrics).cells.first)
        #expect(full.fill == full.area)
        let missing = try #require(BatteryPill.single(left: nil, metrics: metrics).cells.first)
        #expect(missing.fill.width == 0)
        #expect(missing.text == "—")
    }

    @Test func singleCodexBatteryIsTheSameShapeInCodexColour() throws {
        let claude = BatteryPill.single(left: 40, metrics: metrics)
        let codex = BatteryPill.single(left: 40, tool: .codex, metrics: metrics)
        let cell = try #require(codex.cells.first)
        #expect(cell.tool == .codex)
        #expect(codex.body == claude.body)
        #expect(cell.fill == claude.cells.first?.fill)
        #expect(codex.divider == nil)
    }

    // MARK: - Claude and Codex

    @Test func dualBodyHoldsTwoCellsAndADividerInTheMiddle() throws {
        let layout = BatteryPill.dual(claudeLeft: 68, codexLeft: 40, metrics: metrics)
        // 2 + 38 + 1 + 38 + 2
        #expect(layout.body == PillRect(x: 0, y: 0, width: 81, height: 18))
        let divider = try #require(layout.divider)
        #expect(divider == PillRect(x: 40, y: 1, width: 1, height: 16))
        #expect(layout.body.midX == divider.midX)
        #expect(layout.width == 81)
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
        let singles = Set(readings.map { BatteryPill.single(left: $0, metrics: metrics).width })
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
            cornerRadius: 0, dividerWidth: 1,
        )
        let layout = BatteryPill.dual(claudeLeft: 50, codexLeft: 50, metrics: tiny)
        #expect(layout.inner.height == 0)
        #expect(layout.innerRadius == 0)
        #expect(layout.cells.allSatisfy { $0.fill.width >= 0 && $0.area.width >= 0 })
    }
}
