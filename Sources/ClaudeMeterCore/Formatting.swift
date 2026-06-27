import Foundation

/// Display helpers shared by the menu-bar label and the dropdown view.
public enum Formatting {
    /// Render a 0...100 value as a whole-percent string, e.g. `37%`.
    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// Compact countdown for a duration: `2h14m`, `47m`, `8s`, or `now`.
    public static func countdown(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        guard total > 0 else { return "now" }

        let hours = total / 3600
        let minutes = (total % 3600) / 60

        if hours > 0 { return "\(hours)h\(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }
}
