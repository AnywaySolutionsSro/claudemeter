import ClaudeMeterCore
import Foundation
import UserNotifications

/// Thin wrapper over `UNUserNotificationCenter` for threshold nudges, reset celebrations, and
/// "remind me at reset" scheduling.
final class NotificationManager {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func deliver(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// 80/90/100%-used nudge. `remaining` is percent left; `etaToReset` seconds until reset.
    func notifyThreshold(_ threshold: Double, remaining: Double, etaToReset: TimeInterval?) {
        let left = Formatting.percent(remaining)
        let resetPart = etaToReset.map { " · resets in \(Formatting.countdown($0))" } ?? ""
        let (title, body): (String, String)
        switch threshold {
        case 100...:
            (title, body) = ("Out of session budget ⛽", "0% left\(resetPart).")
        case 90:
            (title, body) = ("Running on fumes 🔥", "\(left) left\(resetPart).")
        default:
            (title, body) = ("Heads up", "\(left) of your session window left\(resetPart).")
        }
        deliver(title: title, body: body, id: "threshold-\(Int(threshold))")
    }

    /// Window refilled to full.
    func notifyRefill() {
        deliver(
            title: "Tank refilled 🎉",
            body: "Your session window reset — back to full.",
            id: "refill-\(UUID().uuidString)",
        )
    }

    /// Generic one-shot notification for auto-resume status messages.
    func notify(_ title: String, _ body: String) {
        deliver(title: title, body: body, id: UUID().uuidString)
    }

    // MARK: - Updates

    static let updateCategory = "UPDATE_AVAILABLE"
    static let installAction = "INSTALL_UPDATE"
    static let laterAction = "LATER_UPDATE"

    /// Registers the update category (Install / Later buttons) and routes responses
    /// to `responder`. Call once at launch, before any update notification.
    func installUpdateHandling(_ responder: UpdateNotificationResponder) {
        let install = UNNotificationAction(identifier: Self.installAction, title: "Install and relaunch", options: [])
        let later = UNNotificationAction(identifier: Self.laterAction, title: "Later", options: [])
        let category = UNNotificationCategory(
            identifier: Self.updateCategory, actions: [install, later], intentIdentifiers: [], options: [],
        )
        center.setNotificationCategories([category])
        center.delegate = responder
    }

    /// "ClaudeMeter X is available" with Install / Later. One per version: a repeat
    /// check for the same version replaces the pending one instead of stacking.
    func notifyUpdateAvailable(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "ClaudeMeter \(version) is available"
        content.body = "Install it now and ClaudeMeter relaunches by itself, or pick Later."
        content.sound = .default
        content.categoryIdentifier = Self.updateCategory
        center.add(UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil))
    }

    /// Schedule a one-shot "it reset" notification for a future date.
    func scheduleResetReminder(at date: Date) {
        let interval = date.timeIntervalSinceNow
        guard interval > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Session refilled 🎉"
        content.body = "Your Claude session window just reset — back to full."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        center.add(UNNotificationRequest(identifier: "reset-reminder", content: content, trigger: trigger))
    }
}

/// `UNUserNotificationCenterDelegate` for the update notification: routes the
/// Install button (and a plain click on the banner) to the updater, and lets
/// notifications show while the app is frontmost (a menu-bar agent is "active"
/// whenever its popover is open).
final class UpdateNotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    var onInstall: (@MainActor () -> Void)?
    var onOpen: (@MainActor () -> Void)?

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completion: @escaping () -> Void,
    ) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        Task { @MainActor in
            guard category == NotificationManager.updateCategory else { return }
            switch action {
            case NotificationManager.installAction: self.onInstall?()
            case UNNotificationDefaultActionIdentifier: self.onOpen?()
            default: break
            }
        }
        completion()
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void,
    ) {
        completion([.banner, .sound])
    }
}
