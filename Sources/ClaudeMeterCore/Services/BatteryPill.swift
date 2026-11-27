import Foundation

/// An axis-aligned rect in points (origin bottom-left, as AppKit draws).
public struct PillRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var midX: Double { x + width / 2 }
}

/// The measured sizes a battery is laid out from. `cellTextWidth` is the *minimum* figure
/// width (`BatteryPill.minimumFigure` in the menu-bar font), so a short figure like `5%`
/// still leaves a readable cell; a wider figure grows its own cell. The rest are the
/// drawing's fixed proportions.
public struct BatteryMetrics: Equatable, Sendable {
    public let height: Double
    public let cellTextWidth: Double
    /// Clear space either side of the figure inside its cell.
    public let cellPadding: Double
    /// The outline's stroke width.
    public let lineWidth: Double
    /// Gap between the outline's inner edge and the fill.
    public let inset: Double
    public let cornerRadius: Double
    public let dividerWidth: Double

    public init(
        height: Double, cellTextWidth: Double, cellPadding: Double, lineWidth: Double, inset: Double,
        cornerRadius: Double, dividerWidth: Double,
    ) {
        self.height = height
        self.cellTextWidth = cellTextWidth
        self.cellPadding = cellPadding
        self.lineWidth = lineWidth
        self.inset = inset
        self.cornerRadius = cornerRadius
        self.dividerWidth = dividerWidth
    }

    /// How far in from the body's edge the fill area starts.
    var edge: Double { lineWidth + inset }

    /// One cell's width for a figure `textWidth` wide: never below the minimum.
    func cellWidth(forText textWidth: Double) -> Double {
        max(cellTextWidth, textWidth) + 2 * cellPadding
    }
}

/// One tool's compartment: the area it may fill, the fill for its % left, and its figure.
public struct BatteryCell: Equatable, Sendable {
    public let tool: AgentTool
    public let area: PillRect
    /// Anchored per layout; zero-width without a reading (an empty track, never a fake 0%).
    public let fill: PillRect
    public let text: String
}

/// Where everything in a battery goes. `MenuBarLabel` does the drawing.
public struct BatteryLayout: Equatable, Sendable {
    /// The body's outer edge (the outline is stroked half a line inside it).
    public let body: PillRect
    /// The area inside the outline and its inset, which the cells share.
    public let inner: PillRect
    public let innerRadius: Double
    /// The line between Claude's and Codex's halves; `nil` with Claude alone.
    public let divider: PillRect?
    public let cells: [BatteryCell]

    /// Width of the whole image: the body.
    public var width: Double { body.maxX }
    public var height: Double { body.height }
}

/// The menu-bar battery: a rounded body, filled with
/// each tool's % left. One tool alone fills the whole body from the left and drains from
/// the right; with Codex the body splits in the middle, and each half's fill is anchored
/// at the divider and drains from its outer edge. The pure geometry.
public enum BatteryPill {
    /// The narrowest a cell's figure is taken to be (`5%` and `—` still get this much).
    public static let minimumFigure = "00%"

    /// Share of a cell to fill (0...1); an unknown figure fills nothing.
    public static func level(percentLeft: Double?) -> Double {
        guard let percentLeft else { return 0 }
        return max(0, min(1, percentLeft / 100))
    }

    /// `68%`, or `—` without a reading.
    public static func figure(percentLeft: Double?) -> String {
        percentLeft.map(Formatting.percent) ?? "—"
    }

    /// One tool alone (Claude by default, or Codex when it is the only one shown): one
    /// cell over the whole body in that tool's colour, filled from the left.
    /// `measure` gives a figure's width in the menu-bar font; the cell follows its figure.
    public static func single(left: Double?, tool: AgentTool = .claude, metrics: BatteryMetrics,
                              measure: (String) -> Double = { _ in 0 }) -> BatteryLayout {
        let text = figure(percentLeft: left)
        let frame = frame(innerWidth: metrics.cellWidth(forText: measure(text)), metrics: metrics)
        let fillWidth = frame.inner.width * level(percentLeft: left)
        let fill = PillRect(x: frame.inner.x, y: frame.inner.y, width: fillWidth, height: frame.inner.height)
        let cell = BatteryCell(tool: tool, area: frame.inner, fill: fill, text: text)
        return BatteryLayout(body: frame.body, inner: frame.inner, innerRadius: frame.innerRadius,
                             divider: nil, cells: [cell])
    }

    /// Claude on the left, Codex on the right; both fills meet at the divider.
    /// Each half is as wide as its own figure (see `single` for `measure`).
    public static func dual(claudeLeft: Double?, codexLeft: Double?, metrics: BatteryMetrics,
                            measure: (String) -> Double = { _ in 0 }) -> BatteryLayout {
        let claudeText = figure(percentLeft: claudeLeft)
        let codexText = figure(percentLeft: codexLeft)
        let claudeCell = metrics.cellWidth(forText: measure(claudeText))
        let codexCell = metrics.cellWidth(forText: measure(codexText))
        let frame = frame(innerWidth: claudeCell + codexCell + metrics.dividerWidth, metrics: metrics)
        let inner = frame.inner
        let divider = PillRect(x: inner.x + claudeCell, y: metrics.lineWidth, width: metrics.dividerWidth,
                               height: max(0, metrics.height - 2 * metrics.lineWidth))
        let claudeArea = PillRect(x: inner.x, y: inner.y, width: claudeCell, height: inner.height)
        let codexArea = PillRect(x: divider.maxX, y: inner.y, width: codexCell, height: inner.height)
        let claudeWidth = claudeCell * level(percentLeft: claudeLeft)
        let codexWidth = codexCell * level(percentLeft: codexLeft)
        let claude = BatteryCell(
            tool: .claude, area: claudeArea,
            fill: PillRect(x: divider.x - claudeWidth, y: inner.y, width: claudeWidth, height: inner.height),
            text: claudeText,
        )
        let codex = BatteryCell(
            tool: .codex, area: codexArea,
            fill: PillRect(x: divider.maxX, y: inner.y, width: codexWidth, height: inner.height),
            text: codexText,
        )
        return BatteryLayout(body: frame.body, inner: inner, innerRadius: frame.innerRadius,
                             divider: divider, cells: [claude, codex])
    }

    /// Origin that centres a `textWidth`×`textHeight` figure in `cell`.
    public static func textOrigin(textWidth: Double, textHeight: Double, in cell: PillRect) -> (x: Double, y: Double) {
        (cell.x + (cell.width - textWidth) / 2, cell.y + (cell.height - textHeight) / 2)
    }

    /// The parts every battery shares, before the cells are laid in.
    private struct Frame {
        let body: PillRect
        let inner: PillRect
        let innerRadius: Double
    }

    private static func frame(innerWidth: Double, metrics: BatteryMetrics) -> Frame {
        let edge = metrics.edge
        let height = metrics.height
        let body = PillRect(x: 0, y: 0, width: innerWidth + 2 * edge, height: height)
        let inner = PillRect(x: edge, y: edge, width: innerWidth, height: max(0, height - 2 * edge))
        let radius = max(0, min(metrics.cornerRadius - edge, inner.width / 2, inner.height / 2))
        return Frame(body: body, inner: inner, innerRadius: radius)
    }
}
