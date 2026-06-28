import AppKit
import SwiftUI

/// Owns the Live Sessions window. The window hosts `SessionsView` bound to a
/// shared `SessionMonitor`; monitoring runs only while the window is open.
@MainActor
final class SessionsWindowController: NSObject, NSWindowDelegate {
    private let monitor: SessionMonitor
    private var window: NSWindow?

    init(monitor: SessionMonitor) {
        self.monitor = monitor
        super.init()
    }

    /// Show the window (creating it lazily) and start live scanning.
    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SessionsView(monitor: monitor))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Claude Sessions"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 420, height: 480))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        monitor.start()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Stop scanning when the user dismisses the window.
        monitor.stop()
    }
}
