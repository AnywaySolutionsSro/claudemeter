import AppKit
import SwiftUI
import Combine

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
    private lazy var sessionsWindow = SessionsWindowController(monitor: sessionMonitor)
    private lazy var settingsWindow = SettingsWindowController(settings: settings, auth: auth)

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var labelTimer: Timer?
    private var outsideClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.enableOnFirstLaunchIfNeeded()
        installEditMenu()
        if settings.notificationsEnabled { notifications.requestAuthorization() }

        // Fixed width (content centered) so switching modes / changing the countdown never
        // resizes the item — that would shift the button and misalign the open popover.
        statusItem = NSStatusBar.system.statusItem(withLength: MenuBarLabel.recommendedSlotWidth())
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

        // Redraw the bar on usage/auth/settings changes (e.g. async refresh, mode switch).
        for publisher in [store.objectWillChange, auth.objectWillChange, settings.objectWillChange] {
            publisher.receive(on: RunLoop.main)
                .sink { [weak self] in self?.updateLabel() }
                .store(in: &cancellables)
        }

        hotKey.onActivate = { [weak self] in self?.togglePopover() }
        hotKey.register()

        if auth.isSignedIn { store.start() }
        updateLabel()
        DispatchQueue.main.async { [weak self] in self?.updateLabel() }

        labelTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateLabel() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleThemeChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil
        )
    }

    private func handle(_ event: UsageEvent) {
        switch event {
        case .reset:
            if settings.notificationsEnabled { notifications.notifyRefill() }
        case .crossedThreshold(let threshold, let remaining, let eta):
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
        let signedIn = auth.isSignedIn
        let snapshot = store.snapshot
        let burn = store.burnEstimate
        let error = store.errorMessage
        let now = Date()

        var image = NSImage()
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            image = MenuBarLabel.image(
                mode: mode, signedIn: signedIn, snapshot: snapshot, burn: burn, errorMessage: error, now: now
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
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
            .environmentObject(store)
            .environmentObject(auth)
            .environmentObject(settings)
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
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

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        removeOutsideClickMonitor()
    }
}
