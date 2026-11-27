import Foundation

/// The y-axis top of a usage sparkline (the floor is always 0). A fixed 0–100 scale
/// drew a week at 10 → 11% as a flat line on the floor; the top follows the data
/// instead, with headroom, on a round number.
public enum SparklineScale {
    /// Never zoom in tighter than 0–10%: a 1-point wobble must not fill the chart.
    static let minimumTop: Double = 10
    /// Space above the highest value, as a share of it.
    static let headroom = 0.15
    /// The top is rounded up to a multiple of this.
    static let step: Double = 5

    /// `max(values)` plus headroom, rounded up to the next 5, kept within 10...100.
    public static func top(for values: [Double]) -> Double {
        let peak = max(0, values.max() ?? 0)
        let rounded = (peak * (1 + headroom) / step).rounded(.up) * step
        return min(100, max(minimumTop, rounded))
    }
}
