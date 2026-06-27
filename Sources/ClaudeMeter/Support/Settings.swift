import Foundation
import SwiftUI

/// How the menu-bar item presents usage.
enum DisplayMode: String, CaseIterable, Identifiable {
    case percentage
    case burnRate
    case mood
    case fuelGauge
    case pet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .percentage: return "Percentage"
        case .burnRate: return "Burn rate"
        case .mood: return "Mood face"
        case .fuelGauge: return "Fuel gauge"
        case .pet: return "Pet"
        }
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
        self.displayMode = DisplayMode(rawValue: defaults.string(forKey: Keys.displayMode) ?? "") ?? .percentage
        self.notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        self.lowUsageShortcut = defaults.string(forKey: Keys.lowUsageShortcut) ?? ""
    }

    private enum Keys {
        static let displayMode = "displayMode"
        static let notificationsEnabled = "notificationsEnabled"
        static let lowUsageShortcut = "lowUsageShortcut"
    }
}
