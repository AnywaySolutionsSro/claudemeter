import AppKit
import ClaudeMeterCore
import Combine

// MARK: - Codex

extension AppDelegate {
    /// Codex limit readings arrive with each session scan; alerts (and the menu-bar ring) start only once Codex
    /// is present, and that is also when its alerts first need the notification permission.
    func installCodex() {
        sessionMonitor.onCodexLimits = { [weak self] snapshot, now in
            guard let self, self.sessionMonitor.codexPresent else { return }
            self.limitAlerts.ingest(tool: .codex, snapshot: snapshot, now: now)
        }
        sessionMonitor.$codexPresent
            .removeDuplicates()
            .filter(\.self)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.settings.codexNotificationsEnabled { self.notifications.requestAuthorization() }
                self.updateLabel()
            }
            .store(in: &cancellables)
        // A new reading, or a reset passing, changes Codex's half of the battery.
        sessionMonitor.$codexLimits
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLabel() }
            .store(in: &cancellables)
        installCodexLive()
    }

    /// Live Codex limits from ChatGPT while signed in; each new reading rescans at once
    /// so the merged reading (`CodexLimitSource.pick`) reaches every surface.
    func installCodexLive() {
        sessionMonitor.liveCodexProvider = { [weak self] in self?.codexLive.reading }
        codexLive.onReading = { [weak self] in Task { await self?.sessionMonitor.refresh() } }
        chatGPTAuth.onSignedIn = { [weak self] in self?.codexLive.start() }
        chatGPTAuth.onSignedOut = { [weak self] in
            self?.codexLive.clear()
            Task { await self?.sessionMonitor.refresh() }
        }
        if chatGPTAuth.isSignedIn { codexLive.start() }
    }

    /// Whether the menu-bar battery carries Codex's half next to Claude's.
    var showsCodexInMenuBar: Bool {
        CodexDisplay.showsCodexInMenuBar(enabled: settings.showCodexInMenuBar,
                                         present: sessionMonitor.codexPresent)
    }
}

extension AppDelegate {
    /// One Claude usage event → its notification. Claude titles name the tool only
    /// once Codex is present, so a Claude-only user sees the pre-Codex copy.
    func handle(_ event: UsageEvent) {
        switch event {
        case let .reset(window):
            if settings.notificationsEnabled {
                notifications.notifyRefill(window, tool: .claude, codexPresent: sessionMonitor.codexPresent)
            }
        case let .crossedThreshold(threshold, window, eta):
            if settings.notificationsEnabled {
                notifications.notifyThreshold(
                    threshold, window: window, etaToReset: eta, tool: .claude,
                    codexPresent: sessionMonitor.codexPresent,
                )
            }
        case let .extraUsage(alert, usage):
            if settings.extraUsageNotificationsEnabled {
                notifications.notifyExtraUsage(alert, usage: usage)
            }
        }
    }
}
