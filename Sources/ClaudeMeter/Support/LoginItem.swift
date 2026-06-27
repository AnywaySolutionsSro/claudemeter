import Foundation
import ServiceManagement

/// Manages "start at login" using the modern `SMAppService` API (macOS 13+).
/// Registering the main app makes macOS relaunch it on boot / login; it appears in
/// System Settings → General → Login Items.
enum LoginItem {
    private static let autoRegisterKey = "didAutoRegisterLoginItem"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("ClaudeMeter: login-item change failed: \(error.localizedDescription)")
            return false
        }
    }

    /// On the very first launch, enable start-at-login by default (the app is meant to be
    /// always-on). The user can turn it off from the dropdown afterwards.
    static func enableOnFirstLaunchIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: autoRegisterKey) else { return }
        defaults.set(true, forKey: autoRegisterKey)
        setEnabled(true)
    }
}
