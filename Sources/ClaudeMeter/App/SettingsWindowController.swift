import AppKit
import Combine
import SwiftUI

/// Owns the Settings window, hosting `SettingsView` bound to the shared
/// `Settings` and `AuthModel`.
@MainActor
final class SettingsWindowController: NSObject {
    private let settings: Settings
    private let auth: AuthModel
    private let updates: UpdateService
    private let apiSpend: ApiSpendStore
    private let monitor: SessionMonitor
    private var window: NSWindow?
    private var hosting: NSHostingController<SettingsView>?
    private var presenceWatch: AnyCancellable?

    init(
        settings: Settings, auth: AuthModel, updates: UpdateService, apiSpend: ApiSpendStore,
        monitor: SessionMonitor,
    ) {
        self.settings = settings
        self.auth = auth
        self.updates = updates
        self.apiSpend = apiSpend
        self.monitor = monitor
        super.init()
    }

    private func makeView(codexPresent: Bool) -> SettingsView {
        SettingsView(
            settings: settings, auth: auth, updates: updates, apiSpend: apiSpend,
            codexPresent: codexPresent,
        )
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: makeView(codexPresent: monitor.codexPresent))
            self.hosting = hosting
            // Observe only the presence flag, not the whole monitor: it republishes every
            // 10 s scan, which would re-render the window for nothing.
            presenceWatch = monitor.$codexPresent
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] present in
                    guard let self else { return }
                    self.hosting?.rootView = self.makeView(codexPresent: present)
                }
            // A hosted NSWindow does not follow its root view's preferred size on
            // its own, unlike NSPopover. Without this, `SettingsView`'s reactive
            // frame changes when the text size setting changes but the window keeps
            // its old frame, clipping the larger content in a non-resizable window.
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "ClaudeMeter Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
