import ClaudeMeterCore
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
        case .classic: "Classic" // percentage + reset countdown
        case .burnRate: "Burn rate"
        case .mood: "Mood face"
        case .fuelGauge: "Fuel gauge"
        case .pet: "Pet"
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

    @Published var textScale: TextScale {
        didSet { defaults.set(textScale.rawValue, forKey: Keys.textScale) }
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    @Published var lowUsageShortcut: String {
        didSet { defaults.set(lowUsageShortcut, forKey: Keys.lowUsageShortcut) }
    }

    @Published var autoResumeEnabled: Bool {
        didSet { defaults.set(autoResumeEnabled, forKey: Keys.autoResumeEnabled) }
    }

    @Published var autoResumeContinueText: String {
        didSet { defaults.set(autoResumeContinueText, forKey: Keys.autoResumeContinueText) }
    }

    /// Continue text to type, trimmed; defaults to "continue" when blank.
    var normalizedContinueText: String {
        let trimmed = autoResumeContinueText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "continue" : trimmed
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.displayMode = DisplayMode.fromStored(defaults.string(forKey: Keys.displayMode))
        self.textScale = TextScale.fromStored(defaults.string(forKey: Keys.textScale))
        self.notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        self.lowUsageShortcut = defaults.string(forKey: Keys.lowUsageShortcut) ?? ""
        // Master switch defaults OFF for fresh installs: enabling it in Settings is
        // the deliberate opt-in that also surfaces the iTerm2 Automation consent
        // (with visible status). The fallback only applies when the key was never
        // written — any user who has ever flipped the switch keeps their choice
        // across updates (didSet persists it).
        self.autoResumeEnabled = defaults.object(forKey: Keys.autoResumeEnabled) as? Bool ?? false
        self.autoResumeContinueText = defaults.string(forKey: Keys.autoResumeContinueText) ?? "continue"
    }

    private enum Keys {
        static let displayMode = "displayMode"
        static let textScale = "textScale"
        static let notificationsEnabled = "notificationsEnabled"
        static let lowUsageShortcut = "lowUsageShortcut"
        static let autoResumeEnabled = "autoResumeEnabled"
        static let autoResumeContinueText = "autoResumeContinueText"
    }
}
