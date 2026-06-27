import AppKit
import SwiftUI
import Combine

/// Owns the status-bar item and the popover. Designed for near-zero idle cost:
///  • usage is polled every 5 minutes (tiny JSON), plus on popover-open and on wake;
///  • the menu-bar label refreshes on a 30 s timer (countdown is minute-granular);
///  • the per-second SwiftUI ticker exists only while the popover is open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let account = AccountStore()
    private lazy var store = UsageStore(client: UsageClient(account: account))
    private lazy var auth = AuthModel(account: account)

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var labelTimer: Timer?
    private var outsideClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.enableOnFirstLaunchIfNeeded()
        installEditMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        // Start/stop polling as auth state changes.
        auth.onSignedIn = { [weak self] in
            self?.store.start()
            self?.updateLabel()
        }
        auth.onSignedOut = { [weak self] in
            self?.store.clear()
            self?.updateLabel()
        }
        // Redraw the bar whenever usage or auth state changes (e.g. when an async refresh
        // returns), not just on the 30 s tick. `receive(on:)` defers a tick so the published
        // values are already updated when we read them.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateLabel() }
            .store(in: &cancellables)
        auth.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateLabel() }
            .store(in: &cancellables)

        if auth.isSignedIn { store.start() }
        updateLabel()
        // Redraw once more after the status button is fully realized, to avoid a blank/black
        // pill on a cold launch.
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

    /// Agent apps have no menu bar, so standard keyboard shortcuts (Cmd+V/C/X/A) don't reach
    /// text fields. Installing a minimal Edit menu restores them via the responder chain.
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

    @objc private func handleThemeChange() {
        updateLabel()
    }

    private func updateLabel() {
        guard let button = statusItem.button else { return }
        let signedIn = auth.isSignedIn
        let snapshot = store.snapshot
        let error = store.errorMessage
        let now = Date()

        var image = NSImage()
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            image = MenuBarLabel.image(signedIn: signedIn, snapshot: snapshot, errorMessage: error, now: now)
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

        let content = MenuContentView()
            .environmentObject(store)
            .environmentObject(auth)
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

        if auth.isSignedIn {
            Task { await store.refresh(); updateLabel() }
        }
    }

    private func closePopover() {
        if popover.isShown { popover.performClose(nil) }
        removeOutsideClickMonitor()
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
