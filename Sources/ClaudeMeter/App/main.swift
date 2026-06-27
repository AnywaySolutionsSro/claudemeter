import AppKit

// Menu-bar–only agent: no Dock icon, no main window, no Cmd-Tab entry.
// Top-level code is nonisolated, but it executes on the main thread, so we assume main-actor
// isolation to construct the @MainActor delegate. `run()` blocks here, keeping `delegate` alive.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
