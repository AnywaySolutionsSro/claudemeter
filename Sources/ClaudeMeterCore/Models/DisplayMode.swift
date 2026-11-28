import Foundation

/// How the menu-bar item presents usage.
public enum DisplayMode: String, CaseIterable, Identifiable, Sendable {
    case battery
    case classic
    case burnRate
    case mood
    case fuelGauge
    case pet

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .battery: "Battery"
        case .classic: "Classic" // percentage + reset countdown
        case .burnRate: "Burn rate"
        case .mood: "Mood face"
        case .fuelGauge: "Fuel gauge"
        case .pet: "Pet"
        }
    }

    /// Map a persisted value to a mode. Nothing stored (a new user, or someone who never
    /// picked one) or an unknown value gets the battery; an explicitly picked mode is kept,
    /// including the legacy `"percentage"` key, which is Classic.
    public static func fromStored(_ raw: String?) -> DisplayMode {
        if raw == "percentage" { return .classic }
        return raw.flatMap(DisplayMode.init(rawValue:)) ?? .battery
    }
}
