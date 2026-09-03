import ClaudeMeterCore
import Foundation
import os
import UserNotifications

/// Thin wrapper over `UNUserNotificationCenter` for threshold nudges, reset celebrations, and
/// "remind me at reset" scheduling.
final class NotificationManager {
    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "com.jakubzak.claudemeter", category: "notifications")

    /// Idempotent: macOS prompts once and answers silently afterwards.
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [log] granted, error in
            if let error {
                log.notice("authorization request failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                log.notice("notifications not granted — auto-resume outcomes will not be shown")
            }
        }
    }

    private func deliver(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// A dropped notification is invisible by definition, so the reason has to be logged.
    private func add(_ request: UNNotificationRequest) {
        center.add(request) { [log] error in
            guard let error else { return }
            log
                .notice(
                    "notification \(request.identifier, privacy: .public) dropped: \(error.localizedDescription, privacy: .public)",
                )
        }
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
    static let readyCategory = "UPDATE_READY"
    static let restartNowAction = "RESTART_NOW"
    static let remindLaterAction = "REMIND_LATER"
    static let installOnRestartAction = "INSTALL_ON_RESTART"

    /// Registers the update categories and routes responses to `responder`. Call once
    /// at launch, before any update notification. "Available" (download-only installs)
    /// has Install / Later; "Ready" (a verified bundle waiting) has the three choices.
    func installUpdateHandling(_ responder: UpdateNotificationResponder) {
        let install = UNNotificationAction(identifier: Self.installAction, title: "Download", options: [])
        let later = UNNotificationAction(identifier: Self.laterAction, title: "Later", options: [])
        let available = UNNotificationCategory(
            identifier: Self.updateCategory, actions: [install, later], intentIdentifiers: [], options: [],
        )
        let restart = UNNotificationAction(identifier: Self.restartNowAction, title: "Restart now", options: [])
        let remind = UNNotificationAction(
            identifier: Self.remindLaterAction,
            title: "Remind me in 2 hours",
            options: [],
        )
        let onRestart = UNNotificationAction(
            identifier: Self.installOnRestartAction, title: "Install on next restart", options: [],
        )
        let ready = UNNotificationCategory(
            identifier: Self.readyCategory, actions: [restart, remind, onRestart], intentIdentifiers: [], options: [],
        )
        center.setNotificationCategories([available, ready])
        center.delegate = responder
    }

    /// "ClaudeMeter X is ready to install" with Restart now / Remind me / On next restart.
    /// One per version: a reminder replaces the pending one instead of stacking.
    func notifyUpdateReady(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "ClaudeMeter \(version) is ready to install"
        content.body = "Restart ClaudeMeter to finish the update, or pick a later moment."
        content.sound = .default
        content.categoryIdentifier = Self.readyCategory
        add(UNNotificationRequest(identifier: "ready-\(version)", content: content, trigger: nil))
    }

    /// "ClaudeMeter X is available" with Install / Later. One per version: a repeat
    /// check for the same version replaces the pending one instead of stacking.
    func notifyUpdateAvailable(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "ClaudeMeter \(version) is available"
        content.body = "This copy can't update itself here — Download opens the release page."
        content.sound = .default
        content.categoryIdentifier = Self.updateCategory
        add(UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil))
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
        add(UNNotificationRequest(identifier: "reset-reminder", content: content, trigger: trigger))
    }
}

/// `UNUserNotificationCenterDelegate` for the update notification: routes the
/// Install button (and a plain click on the banner) to the updater, and lets
/// notifications show while the app is frontmost (a menu-bar agent is "active"
/// whenever its popover is open).
final class UpdateNotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    var onInstall: (@MainActor () -> Void)?
    var onOpen: (@MainActor () -> Void)?
    var onRestartNow: (@MainActor () -> Void)?
    var onRemindLater: (@MainActor () -> Void)?
    var onInstallOnRestart: (@MainActor () -> Void)?

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completion: @escaping () -> Void,
    ) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        Task { @MainActor in
            switch (category, action) {
            case (NotificationManager.updateCategory, NotificationManager.installAction): self.onInstall?()
            case (NotificationManager.readyCategory, NotificationManager.restartNowAction): self.onRestartNow?()
            case (NotificationManager.readyCategory, NotificationManager.remindLaterAction): self.onRemindLater?()
            case (NotificationManager.readyCategory, NotificationManager.installOnRestartAction):
                self.onInstallOnRestart?()
            case (NotificationManager.updateCategory, UNNotificationDefaultActionIdentifier),
                 (NotificationManager.readyCategory, UNNotificationDefaultActionIdentifier):
                self.onOpen?()
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
