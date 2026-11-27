import ClaudeMeterCore
import Foundation
import SwiftUI

/// User preferences, backed by `UserDefaults`.
@MainActor
final class Settings: ObservableObject {
    @Published var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Keys.displayMode) }
    }

    @Published var textScale: TextScale {
        didSet { defaults.set(textScale.rawValue, forKey: Keys.textScale) }
    }

    /// 12-hour / 24-hour / follow the system, for every time the app and widgets show.
    @Published var clockStyle: ClockStyle {
        didSet { defaults.set(clockStyle.rawValue, forKey: Keys.clockStyle) }
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    /// Threshold and refill alerts for Codex's limits, reported separately from Claude's.
    @Published var codexNotificationsEnabled: Bool {
        didSet { defaults.set(codexNotificationsEnabled, forKey: Keys.codexNotificationsEnabled) }
    }

    /// Show Claude (dropdown, menu-bar battery, widget, alerts, auto-resume). The toggle
    /// appears once Codex is available; `ToolVisibility` never lets both be hidden.
    @Published var showClaude: Bool {
        didSet { defaults.set(showClaude, forKey: Keys.showClaude) }
    }

    /// Show Codex everywhere Claude can be hidden from. Replaces the old
    /// `showCodexInMenuBar` toggle, whose stored value it takes over once.
    @Published var showCodex: Bool {
        didSet { defaults.set(showCodex, forKey: Keys.showCodex) }
    }

    /// Threshold nudges for paid extra usage (spending started / 80% / cap reached).
    /// On by default: unnoticed paid spend is the failure this feature exists to prevent.
    @Published var extraUsageNotificationsEnabled: Bool {
        didSet { defaults.set(extraUsageNotificationsEnabled, forKey: Keys.extraUsageNotificationsEnabled) }
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

    /// Daily background check for a newer GitHub release (Settings → General → Updates).
    @Published var autoUpdateCheckEnabled: Bool {
        didSet { defaults.set(autoUpdateCheckEnabled, forKey: Keys.autoUpdateCheckEnabled) }
    }

    /// When the updater last asked GitHub, successfully or not; drives the 24 h cadence.
    @Published var lastUpdateCheck: Date? {
        didSet { defaults.set(lastUpdateCheck, forKey: Keys.lastUpdateCheck) }
    }

    /// A version (`01.02.00`) the user chose to skip; never offered again.
    @Published var skippedUpdateVersion: String? {
        didSet { defaults.set(skippedUpdateVersion, forKey: Keys.skippedUpdateVersion) }
    }

    /// A staged version (`01.06.00`) the user chose to install on the next restart:
    /// swapped in when the app quits, or at the next launch if the quit was missed.
    @Published var pendingInstallVersion: String? {
        didSet { defaults.set(pendingInstallVersion, forKey: Keys.pendingInstallVersion) }
    }

    /// The version that ran last time (`01.04.00`); a different running version means
    /// an update just landed and its notes are shown once.
    @Published var lastRunVersion: String? {
        didSet { defaults.set(lastRunVersion, forKey: Keys.lastRunVersion) }
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
        self.clockStyle = ClockStyle(rawValue: defaults.string(forKey: Keys.clockStyle) ?? "") ?? .system
        self.notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        self.codexNotificationsEnabled = defaults.object(forKey: Keys.codexNotificationsEnabled) as? Bool ?? true
        self.showClaude = defaults.object(forKey: Keys.showClaude) as? Bool ?? true
        self.showCodex = Self.migratedShowCodex(defaults)
        self.extraUsageNotificationsEnabled =
            defaults.object(forKey: Keys.extraUsageNotificationsEnabled) as? Bool ?? true
        self.lowUsageShortcut = defaults.string(forKey: Keys.lowUsageShortcut) ?? ""
        // Master switch defaults OFF for fresh installs: enabling it in Settings is
        // the deliberate opt-in that also surfaces the iTerm2 Automation consent
        // (with visible status). The fallback only applies when the key was never
        // written — any user who has ever flipped the switch keeps their choice
        // across updates (didSet persists it).
        self.autoResumeEnabled = defaults.object(forKey: Keys.autoResumeEnabled) as? Bool ?? false
        self.autoResumeContinueText = defaults.string(forKey: Keys.autoResumeContinueText) ?? "continue"
        self.autoUpdateCheckEnabled = defaults.object(forKey: Keys.autoUpdateCheckEnabled) as? Bool ?? true
        self.lastUpdateCheck = defaults.object(forKey: Keys.lastUpdateCheck) as? Date
        self.skippedUpdateVersion = defaults.string(forKey: Keys.skippedUpdateVersion)
        self.lastRunVersion = defaults.string(forKey: Keys.lastRunVersion)
        self.pendingInstallVersion = defaults.string(forKey: Keys.pendingInstallVersion)
    }

    /// `showCodex`, seeded once from the retired `showCodexInMenuBar` (whose key is then
    /// removed), so someone who had switched Codex off keeps it off.
    private static func migratedShowCodex(_ defaults: UserDefaults) -> Bool {
        if let stored = defaults.object(forKey: Keys.showCodex) as? Bool { return stored }
        let legacy = defaults.object(forKey: Keys.legacyShowCodexInMenuBar) as? Bool ?? true
        defaults.set(legacy, forKey: Keys.showCodex)
        defaults.removeObject(forKey: Keys.legacyShowCodexInMenuBar)
        return legacy
    }

    private enum Keys {
        static let displayMode = "displayMode"
        static let textScale = "textScale"
        static let clockStyle = "clockStyle"
        static let notificationsEnabled = "notificationsEnabled"
        static let codexNotificationsEnabled = "codexNotificationsEnabled"
        static let extraUsageNotificationsEnabled = "extraUsageNotificationsEnabled"
        static let showClaude = "showClaude"
        static let showCodex = "showCodex"
        static let legacyShowCodexInMenuBar = "showCodexInMenuBar"
        static let lowUsageShortcut = "lowUsageShortcut"
        static let autoResumeEnabled = "autoResumeEnabled"
        static let autoResumeContinueText = "autoResumeContinueText"
        static let autoUpdateCheckEnabled = "autoUpdateCheckEnabled"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let skippedUpdateVersion = "skippedUpdateVersion"
        static let lastRunVersion = "lastRunVersion"
        static let pendingInstallVersion = "pendingInstallVersion"
    }
}
