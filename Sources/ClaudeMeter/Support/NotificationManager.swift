import Foundation
import UserNotifications
import ClaudeMeterCore

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
        deliver(title: "Tank refilled 🎉", body: "Your session window reset — back to full.", id: "refill-\(UUID().uuidString)")
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
