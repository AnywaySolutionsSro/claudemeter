import Foundation
import SwiftUI

/// How the menu-bar item presents usage.
enum DisplayMode: String, CaseIterable, Identifiable {
    case classic
    case burnRate
    case mood
    case fuelGauge
    case pet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Classic"          // percentage + reset countdown
        case .burnRate: return "Burn rate"
        case .mood: return "Mood face"
        case .fuelGauge: return "Fuel gauge"
        case .pet: return "Pet"
        }
    }

    /// Map persisted values, including the legacy `"percentage"` key, to a mode.
    static func fromStored(_ raw: String?) -> DisplayMode {
        if raw == "percentage" { return .classic }
        return DisplayMode(rawValue: raw ?? "") ?? .classic
    }
}

/// User preferences, backed by `UserDefaults`.
@MainActor
final class Settings: ObservableObject {
    @Published var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Keys.displayMode) }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }
    @Published var lowUsageShortcut: String {
        didSet { defaults.set(lowUsageShortcut, forKey: Keys.lowUsageShortcut) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.displayMode = DisplayMode.fromStored(defaults.string(forKey: Keys.displayMode))
        self.notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        self.lowUsageShortcut = defaults.string(forKey: Keys.lowUsageShortcut) ?? ""
    }

    private enum Keys {
        static let displayMode = "displayMode"
        static let notificationsEnabled = "notificationsEnabled"
        static let lowUsageShortcut = "lowUsageShortcut"
    }
}
