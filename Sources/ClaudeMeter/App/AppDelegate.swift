import AppKit
import ClaudeMeterCore
import Combine
import SwiftUI

/// Owns the status-bar item and popover. See inline notes on the near-zero-idle design.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let account = AccountStore()
    private let settings = Settings()
    private let notifications = NotificationManager()
    private let hotKey = HotKey()
    private lazy var store = UsageStore(client: UsageClient(account: account))
    private lazy var auth = AuthModel(account: account)
    private let sessionMonitor = SessionMonitor()
    private lazy var sessionsWindow = SessionsWindowController(
        monitor: sessionMonitor, armed: armedSessions, settings: settings,
        onTestResume: { [weak self] session in
            guard let self else { return }
            self.autoResume.testResume(
                session: session,
                processes: self.sessionMonitor.latestProcesses,
                paths: { LibprocProcessProbe.executablePathForPID($0) },
                parents: { LibprocProcessProbe.parentPIDForPID($0) },
            )
        },
    )
    private lazy var settingsWindow = SettingsWindowController(settings: settings, auth: auth)
    private let armedSessions = ArmedSessions()
    private let sleepInhibitor = SleepInhibitor()
    private lazy var autoResume = AutoResumeCoordinator(
        armed: armedSessions,
        settings: settings,
        notify: { [weak self] message in self?.notifications.notify("ClaudeMeter", message) },
    )

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var labelTimer: Timer?
    private var outsideClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_: Notification) {
        LoginItem.enableOnFirstLaunchIfNeeded()
        installEditMenu()
        if settings.notificationsEnabled { notifications.requestAuthorization() }

        // Fixed width (content centered) so switching modes / changing the countdown never
        // resizes the item — that would shift the button and misalign the open popover.
        statusItem = NSStatusBar.system
            .statusItem(withLength: MenuBarLabel.recommendedSlotWidth(for: settings.textScale))
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            button.imagePosition = .imageOnly
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        auth.onSignedIn = { [weak self] in self?.store.start(); self?.updateLabel() }
        auth.onSignedOut = { [weak self] in self?.store.clear(); self?.updateLabel() }
        store.onEvent = { [weak self] in self?.handle($0) }
        store.onAuthExpired = { [weak self] in self?.auth.sessionExpired() }

        // Redraw the bar on usage/auth/settings changes (e.g. async refresh, mode switch).
        for publisher in [store.objectWillChange, auth.objectWillChange, settings.objectWillChange] {
            publisher.receive(on: RunLoop.main)
                .sink { [weak self] in self?.updateLabel() }
                .store(in: &cancellables)
        }

        hotKey.onActivate = { [weak self] in self?.togglePopover() }
        hotKey.register()

        if auth.isSignedIn { store.start() }

        // Keep scanning local sessions in the background so the widget snapshot
        // stays fresh even when the Sessions window is closed.
        sessionMonitor.start()

        // Feed armed IDs into published snapshots and run auto-resume after each scan.
        sessionMonitor.armedIDsProvider = { [weak self] in Array(self?.armedSessions.armed ?? []) }
        // Carry account usage windows (Session / Weekly / …) into the widget snapshot.
        sessionMonitor.usageProvider = { [weak self] in self?.store.snapshot }
        sessionMonitor.onScan = { [weak self] inputs in
            guard let self else { return }
            // Apply any arm/disarm requests issued from the widget. Arm requests
            // are re-validated against the current armable set.
            let armable = Set(inputs.armableIDs)
            if self.armedSessions.drainWidgetCommands(isArmable: { armable.contains($0) }) {
                Task { await self.sessionMonitor.refresh() }
            }
            // Auto-disarm armed sessions whose terminal died (tab closed, /clear):
            // they'd otherwise stay pinned in the widget forever. Grace period in
            // the pruner protects against a transient probe glitch.
            let runningIDs = Set(inputs.sessions.filter { $0.running == .running }.map(\.id))
            let disarmed = self.armedSessions.pruneDead(runningIDs: runningIDs)
            if !disarmed.isEmpty {
                let names = inputs.sessions.filter { disarmed.contains($0.id) }.map(\.projectName)
                let label = names.isEmpty ? "\(disarmed.count) session(s)" : names.joined(separator: ", ")
                self.notifications.notify("ClaudeMeter", "Disarmed \(label) — session no longer running.")
                Task { await self.sessionMonitor.refresh() }
            }
            // Keep the Mac awake while anything is armed.
            self.sleepInhibitor.update(active: !self.armedSessions.armed.isEmpty)
            // Drive auto-resume.
            self.autoResume.handleSnapshot(
                usage: self.store.snapshot,
                sessions: inputs.sessions,
                processes: inputs.processes,
                transcriptTail: { SessionMonitor.tailLines(forSessionID: $0) },
                paths: { LibprocProcessProbe.executablePathForPID($0) },
                parents: { LibprocProcessProbe.parentPIDForPID($0) },
            )
        }
        // React to arming changes immediately (sleep assertion + republish).
        // Arming is also the fallback moment to surface the iTerm2 Automation
        // consent (iTerm2 is guaranteed running then — armable implies it).
        armedSessions.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.sleepInhibitor.update(active: !self.armedSessions.armed.isEmpty)
                self.requestITermAuthorizationIfNeeded()
                Task { await self.sessionMonitor.refresh() }
            }
            .store(in: &cancellables)
        // Republish the widget snapshot when account usage refreshes, so the gauges
        // track the latest Session/Weekly percentages between session scans.
        // $snapshot (deduplicated), NOT objectWillChange: one poll mutates many
        // @Published properties and would schedule that many redundant rescans.
        store.$snapshot
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.sessionMonitor.refresh() } }
            .store(in: &cancellables)

        updateLabel()
        DispatchQueue.main.async { [weak self] in self?.updateLabel() }

        labelTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateLabel() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification, object: nil,
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleThemeChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil,
        )
    }

    /// One-time proactive Automation authorization (the TCC consent prompt),
    /// surfaced when the user first ARMS a session — the moment the feature is
    /// actually enabled, with iTerm2 guaranteed running. (Enabling the master
    /// switch in Settings triggers its own inline authorize with visible status.)
    /// Skipped once answered either way — Settings → "Authorize iTerm2 control"
    /// remains the manual retry.
    private func requestITermAuthorizationIfNeeded() {
        let key = "didRequestITermAutomation"
        guard settings.autoResumeEnabled, !UserDefaults.standard.bool(forKey: key) else { return }
        switch ITermDriver().authorize() {
        case .granted:
            UserDefaults.standard.set(true, forKey: key)
            notifications.notify("ClaudeMeter", "iTerm2 control authorized — auto-resume is ready.")
        case .denied:
            UserDefaults.standard.set(true, forKey: key) // answered; don't nag again
            notifications.notify("ClaudeMeter",
                                 "iTerm2 control was denied — auto-resume can't type into sessions. "
                                     + "Re-enable in System Settings → Privacy & Security → Automation, "
                                     + "or Settings → Authorize iTerm2 control.")
        case .notRunning:
            break // try again on a later launch or when a session is first armed
        }
    }

    private func handle(_ event: UsageEvent) {
        switch event {
        case .reset:
            if settings.notificationsEnabled { notifications.notifyRefill() }
        case let .crossedThreshold(threshold, remaining, eta):
            if settings.notificationsEnabled {
                notifications.notifyThreshold(threshold, remaining: remaining, etaToReset: eta)
            }
            if threshold >= 90 { ShortcutRunner.run(settings.lowUsageShortcut) }
        }
    }

    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func handleWake() {
        guard auth.isSignedIn else { return }
        Task { await store.refresh(); updateLabel() }
    }

    @objc private func handleThemeChange() { updateLabel() }

    private func updateLabel() {
        guard let button = statusItem.button else { return }
        let mode = settings.displayMode
        let scale = settings.textScale
        let signedIn = auth.isSignedIn
        let snapshot = store.snapshot
        let burn = store.burnEstimate
        let error = store.errorMessage
        let now = Date()

        // Re-assert the slot width here, not just at launch: the width is fixed
        // *per scale*, and a text-size change must widen the slot or the new image
        // lands in a stale one. `settings.objectWillChange` already routes here.
        statusItem.length = MenuBarLabel.recommendedSlotWidth(for: scale)

        var image = NSImage()
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            image = MenuBarLabel.image(
                mode: mode, signedIn: signedIn, snapshot: snapshot, burn: burn,
                errorMessage: error, now: now, scale: scale,
            )
        }
        button.image = image
        button.imagePosition = .imageOnly
        button.title = ""
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        if popover.isShown { closePopover() } else { openPopover() }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }

        let content = MenuContentView(
            onOpenSessions: { [weak self] in self?.openSessions() },
            onOpenSettings: { [weak self] in self?.openSettings() },
        )
        .environmentObject(store)
        .environmentObject(auth)
        .environmentObject(settings)
        .environment(\.textScale, settings.textScale)
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }

        if auth.isSignedIn { Task { await store.refresh(); updateLabel() } }
    }

    private func closePopover() {
        if popover.isShown { popover.performClose(nil) }
        removeOutsideClickMonitor()
    }

    /// Open the Live Sessions window (dismissing the popover first).
    func openSessions() {
        closePopover()
        sessionsWindow.show()
    }

    /// Open the Settings window (dismissing the popover first).
    func openSettings() {
        closePopover()
        settingsWindow.show()
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    func popoverDidClose(_: Notification) {
        popover.contentViewController = nil
        removeOutsideClickMonitor()
    }
}
