import AppKit
import SwiftUI

/// Owns the Live Sessions window. The window hosts `SessionsView` bound to the
/// shared `SessionMonitor`, which the app keeps running so the widget snapshot
/// stays fresh even when this window is closed.
@MainActor
final class SessionsWindowController: NSObject {
    private let monitor: SessionMonitor
    private var window: NSWindow?

    init(monitor: SessionMonitor) {
        self.monitor = monitor
        super.init()
    }

    /// Show the window (creating it lazily). Triggers an immediate refresh so the
    /// list is current the moment it appears.
    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SessionsView(monitor: monitor))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Claude Sessions"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 440, height: 640))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        Task { await monitor.refresh() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
