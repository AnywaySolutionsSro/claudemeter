import AppKit
import SwiftUI

/// Owns the Settings window, hosting `SettingsView` bound to the shared
/// `Settings` and `AuthModel`.
@MainActor
final class SettingsWindowController: NSObject {
    private let settings: Settings
    private let auth: AuthModel
    private let updates: UpdateService
    private var window: NSWindow?

    init(settings: Settings, auth: AuthModel, updates: UpdateService) {
        self.settings = settings
        self.auth = auth
        self.updates = updates
        super.init()
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: settings, auth: auth, updates: updates))
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
