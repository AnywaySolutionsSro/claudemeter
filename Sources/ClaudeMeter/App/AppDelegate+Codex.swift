import AppKit
import ClaudeMeterCore
import Combine

// MARK: - Codex

extension AppDelegate {
    /// Codex limit readings arrive with each session scan; alerts (and the menu-bar ring) start only once Codex
    /// is present, and that is also when its alerts first need the notification permission.
    func installCodex() {
        sessionMonitor.widgetToolsProvider = { [weak self] in
            guard let self else { return (limitTools: [.claude], hidden: []) }
            let visibility = self.toolVisibility
            return (limitTools: visibility.limitTools(claudeSignedIn: self.authSignedIn,
                                                      codexConnected: self.chatGPTAuth.isSignedIn),
                    hidden: visibility.hiddenTools)
        }
        // A hidden or shown tool, or a ChatGPT sign-in, changes what the widget shows.
        Publishers.Merge3(
            settings.$showClaude.removeDuplicates().map { _ in () },
            settings.$showCodex.removeDuplicates().map { _ in () },
            chatGPTAuth.$state.removeDuplicates().map { _ in () },
        )
        .dropFirst(3)
        .receive(on: RunLoop.main)
        .sink { [weak self] in Task { await self?.sessionMonitor.refresh() } }
        .store(in: &cancellables)
        sessionMonitor.onCodexLimits = { [weak self] snapshot, now in
            guard let self, self.sessionMonitor.codexPresent else { return }
            // Hidden: no alerts, and no stale baseline — the first reading after showing
            // Codex again seeds silently instead of reading the gap as a refill.
            guard self.toolVisibility.showsCodex else {
                self.limitAlerts.resetBaseline(tool: .codex)
                return
            }
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

    /// The Show Claude / Show Codex settings, resolved (never both hidden; Codex only
    /// once it is present or signed in).
    var toolVisibility: ToolVisibility {
        ToolVisibility(showClaude: settings.showClaude, showCodex: settings.showCodex,
                       codexAvailable: sessionMonitor.codexPresent || chatGPTAuth.isSignedIn)
    }

    /// The tools the menu-bar battery shows: connected and not hidden.
    func menuBarTools(claudeSignedIn: Bool) -> [AgentTool] {
        toolVisibility.limitTools(claudeSignedIn: claudeSignedIn, codexConnected: chatGPTAuth.isSignedIn)
    }
}

extension AppDelegate {
    /// One Claude usage event → its notification. Claude titles name the tool only
    /// once Codex is present, so a Claude-only user sees the pre-Codex copy.
    func handle(_ event: UsageEvent) {
        // A hidden Claude raises no limit alerts (extra-usage spend is money, so it still does).
        let claudeShown = toolVisibility.showsClaude
        switch event {
        case let .reset(window):
            if settings.notificationsEnabled, claudeShown {
                notifications.notifyRefill(window, tool: .claude, codexPresent: sessionMonitor.codexPresent)
            }
        case let .crossedThreshold(threshold, window, eta):
            if settings.notificationsEnabled, claudeShown {
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
