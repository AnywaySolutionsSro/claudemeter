import AppKit
import SwiftUI

/// Owns the Settings window, hosting `SettingsView` bound to the shared
/// `Settings` and `AuthModel`.
@MainActor
final class SettingsWindowController: NSObject {
    private let settings: Settings
    private let auth: AuthModel
    private var window: NSWindow?

    init(settings: Settings, auth: AuthModel) {
        self.settings = settings
        self.auth = auth
        super.init()
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: settings, auth: auth))
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
