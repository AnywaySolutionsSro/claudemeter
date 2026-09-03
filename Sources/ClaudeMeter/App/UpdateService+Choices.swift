import ClaudeMeterCore
import Foundation

/// What the user can do with an update once it is on the table: restart now (see
/// `install()`), remind later, install on the next restart, dismiss, or skip.
extension UpdateService {
    /// "Remind me in 2 hours": hide the prompt; the notification returns when it passes.
    func remindLater(now: Date = Date()) {
        guard case let .ready(release) = state else { return }
        let until = UpdatePolicy.reminderDate(from: now)
        snoozedUntil = until
        reminderTimer?.invalidate()
        reminderTimer = Timer
            .scheduledTimer(withTimeInterval: until.timeIntervalSince(now), repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, case .ready = self.state, !self.isDeferredToRestart else { return }
                    self.snoozedUntil = nil
                    self.onUpdateReady?(release)
                }
            }
        log.notice("snoozed \(release.tagName, privacy: .public) until \(until.description, privacy: .public)")
    }

    /// "Install on next restart": swap the bundle in when the app quits (or at the next
    /// launch if that is missed). The prompt goes away; Settings still says so.
    func installOnNextRestart() {
        guard case let .ready(release) = state else { return }
        snoozedUntil = nil
        reminderTimer?.invalidate()
        settings.pendingInstallVersion = release.version.description
        log.notice("deferred \(release.tagName, privacy: .public) to the next restart")
        objectWillChange.send()
    }

    /// Quit-time hook: perform a deferred install synchronously (no relaunch — the user
    /// is leaving). Errors are logged; the stage stays for the next launch to retry.
    func installPendingOnQuit() {
        guard isDeferredToRestart, let staged, case let .inPlace(bundleURL) = installMode else { return }
        do {
            try installer.installNow(staged, over: bundleURL, relaunch: false)
            settings.pendingInstallVersion = nil
        } catch {
            log
                .error(
                    "quit-time install of \(staged.release.tagName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)",
                )
        }
    }
}
