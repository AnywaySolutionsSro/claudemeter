import AppKit
import ClaudeMeterCore
import Foundation
import os

/// Where the updater is right now; drives the dropdown banner and Settings.
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    /// Found but not downloaded: download-only installs, or a background download that
    /// failed (the banner offers to try again).
    case available(ReleaseInfo)
    /// `progress` in 0...1, or -1 when the size is unknown.
    case downloading(ReleaseInfo, progress: Double)
    /// Downloaded and verified; waiting for "restart now" or the next restart.
    case ready(ReleaseInfo)
    case installing(ReleaseInfo)
    case failed(ReleaseInfo?, message: String)

    var offeredRelease: ReleaseInfo? {
        switch self {
        case let .available(release), let .downloading(release, _), let .ready(release),
             let .installing(release): release
        case let .failed(release, _): release
        case .idle, .checking, .upToDate: nil
        }
    }

    var readyRelease: ReleaseInfo? {
        if case let .ready(release) = self { return release }
        return nil
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing: true
        default: false
        }
    }
}

/// Checks GitHub for a newer release, downloads and verifies it in the background,
/// and asks the user one question once it is ready: restart now, or later?
///
/// Cadence: a check ~1 min after every launch (throttled to once an hour), then an
/// hourly tick that runs a real check only when `UpdatePolicy.isCheckDue` says so,
/// plus a wake-from-sleep hook. A found update that this build can install in place
/// is staged straight away (`UpdateInstaller.stage`, into Application Support so it
/// survives a reboot). "Remind me in 2 hours" snoozes the prompt; "Install on next
/// restart" swaps the bundle in when the app quits (or at the next launch if the
/// quit was missed); "Skip this version" persists and discards the stage.
@MainActor
final class UpdateService: ObservableObject {
    @Published private(set) var state: UpdateState = .idle
    /// "Remind me later" until this date: the prompt is hidden and the notification
    /// fires again when it passes.
    @Published var snoozedUntil: Date?
    /// The GitHub release of the version that is running — its notes are shown
    /// next to an offered update's so the choice is an informed one. Fetched once
    /// per launch alongside the first check; `nil` for dev builds and offline.
    @Published private(set) var currentRelease: ReleaseInfo?
    /// True from launch until acknowledged when the running version differs from the
    /// one that ran last time — i.e. an update just landed; the dropdown shows its notes.
    @Published private(set) var justUpdated = false

    let currentVersion: AppVersion?
    let installMode: InstallMode

    /// Invoked when a *background* check finds an update this build cannot install in
    /// place (the release page is the offer).
    var onUpdateFound: ((ReleaseInfo) -> Void)?
    /// Invoked when a release is downloaded, verified and waiting — and again when a
    /// "remind me later" snooze ends. Drives the restart-now / later notification.
    var onUpdateReady: ((ReleaseInfo) -> Void)?
    /// Invoked when an install attempt fails, with a user-facing message.
    var onInstallFailed: ((String) -> Void)?

    let settings: Settings
    private let client: GitHubReleaseClient
    let installer: UpdateInstaller
    let log = Logger(subsystem: "com.jakubzak.claudemeter", category: "updater")
    private var timer: Timer?
    private var checkTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    var reminderTimer: Timer?
    /// The verified bundle on disk behind `.ready`.
    var staged: StagedUpdate?
    /// Set by `checkAndInstall()` / `install()` on a not-yet-staged release: install as
    /// soon as the stage lands instead of prompting.
    private var installAfterStage = false
    private var isLoadingCurrentRelease = false

    /// True while the dropdown should show the restart prompt: a stage is ready and the
    /// user hasn't snoozed it or deferred it to the next restart.
    var promptVisible: Bool {
        guard case .ready = state else { return false }
        return !isSnoozed && !isDeferredToRestart
    }

    var isSnoozed: Bool {
        guard let snoozedUntil else { return false }
        return Date() < snoozedUntil
    }

    /// The staged version is the one the user chose to install on the next restart.
    var isDeferredToRestart: Bool {
        guard let staged, let pending = settings.pendingInstallVersion else { return false }
        return pending == staged.version.description
    }

    init(
        settings: Settings,
        client: GitHubReleaseClient = GitHubReleaseClient(),
        installer: UpdateInstaller = UpdateInstaller(),
        bundleURL: URL = Bundle.main.bundleURL,
    ) {
        self.settings = settings
        self.client = client
        self.installer = installer
        self.currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap(AppVersion.init)
        self.installMode = UpdatePolicy.installMode(
            bundleURL: bundleURL,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            canWriteParent: { FileManager.default.isWritableFile(atPath: $0.path) },
        )
    }

    // MARK: - Scheduling

    /// Diagnostic launch argument: check immediately and install without a click,
    /// so the real GUI install + relaunch path can be exercised end to end
    /// (`open -a ClaudeMeter --args --install-update-now`).
    static let installNowArgument = "--install-update-now"
    private let installNow = CommandLine.arguments.contains(UpdateService.installNowArgument)

    func start() {
        if installNow {
            log.notice("\(Self.installNowArgument, privacy: .public): checking and installing immediately")
            installAfterStage = true
            check(userInitiated: true)
        }
        let version = currentVersion?.description ?? "unversioned"
        log
            .notice(
                "updater start: running \(version, privacy: .public), mode \(String(describing: self.installMode), privacy: .public)",
            )
        if let currentVersion {
            // A version change since the last run = an update just landed.
            if let previous = settings.lastRunVersion, previous != currentVersion.description {
                justUpdated = true
                log.notice("updated \(previous, privacy: .public) -> \(currentVersion.description, privacy: .public)")
            }
            settings.lastRunVersion = currentVersion.description
            // The running version's notes are wanted right away (Settings, and the
            // post-update banner), not only after the next check.
            Task { [weak self] in await self?.loadCurrentReleaseIfNeeded(latest: nil) }
        }
        adoptStagedFromDisk()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstCheckDelay) { [weak self] in
            self?.checkIfDue(launch: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        timer?.tolerance = Self.tickInterval / 10
    }

    /// Runs a background check when the daily interval has elapsed (also called on wake);
    /// at `launch` the bar is an hour, since a login item relaunches rarely.
    func checkIfDue(now: Date = Date(), launch: Bool = false) {
        guard settings.autoUpdateCheckEnabled, !state.isBusy else { return }
        let due = launch
            ? UpdatePolicy.isLaunchCheckDue(lastCheck: settings.lastUpdateCheck, now: now)
            : UpdatePolicy.isCheckDue(lastCheck: settings.lastUpdateCheck, now: now)
        guard due else { return }
        check(userInitiated: false)
    }

    /// A stage left by an earlier run: install it now if the user asked for "next
    /// restart" and the quit-time swap was missed, otherwise offer it again. A stage
    /// for the running version (the quit-time swap worked) is cleaned up.
    private func adoptStagedFromDisk() {
        guard let found = installer.loadStaged() else { return }
        switch UpdatePolicy.disposition(of: found, current: currentVersion, latest: nil) {
        case .discard, .replace:
            installer.discard(found)
            if settings.pendingInstallVersion == found.version.description { settings.pendingInstallVersion = nil }
        case .keep:
            staged = found
            state = .ready(found.release)
            if isDeferredToRestart {
                log.notice("pending \(found.release.tagName, privacy: .public) found at launch; installing")
                install()
            } else {
                onUpdateReady?(found.release)
            }
        }
    }

    /// "Check now" from Settings — ignores the interval and the auto-check switch.
    func checkNow() { check(userInitiated: true) }

    /// The Install button of a notification that outlived the offer it announced (the
    /// app relaunched, or the offer was dismissed since): re-check and install what's
    /// found. With an offer still on the table this is a plain `install()`.
    func checkAndInstall() {
        if state.offeredRelease != nil, !state.isBusy {
            install()
            return
        }
        installAfterStage = true
        check(userInitiated: true)
    }

    private func check(userInitiated: Bool) {
        guard !state.isBusy else { return }
        let ready = state.readyRelease
        state = .checking
        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let latest = try await client.fetchLatest()
                apply(latest: latest, userInitiated: userInitiated)
                await loadCurrentReleaseIfNeeded(latest: latest)
            } catch {
                log.error("check failed: \(error.localizedDescription, privacy: .public)")
                // A background failure is silent (retry next tick); a manual one is shown.
                // A ready stage is never lost to a failed check.
                if let ready {
                    state = .ready(ready)
                } else {
                    state = userInitiated ? .failed(nil, message: error.localizedDescription) : .idle
                }
            }
        }
    }

    /// The running version's own release: reuse `latest` when it *is* the running
    /// version (no extra call), otherwise one `releases/tags/<tag>` request. Failure
    /// is silent — the notes are a nicety, not a gate.
    private func loadCurrentReleaseIfNeeded(latest: ReleaseInfo?) async {
        guard currentRelease == nil, let currentVersion, !isLoadingCurrentRelease else { return }
        if let latest, latest.version == currentVersion {
            currentRelease = latest
            return
        }
        isLoadingCurrentRelease = true
        defer { isLoadingCurrentRelease = false }
        currentRelease = try? await client.fetchRelease(tag: currentVersion.tagName)
    }

    private func apply(latest: ReleaseInfo?, userInitiated: Bool) {
        let now = Date()
        settings.lastUpdateCheck = now
        let skipped = settings.skippedUpdateVersion.flatMap(AppVersion.init)
        let decision = UpdatePolicy.decide(current: currentVersion, latest: latest, skipped: skipped)
        let latestTag = latest?.tagName ?? "none"
        log.notice("check: latest \(latestTag, privacy: .public) -> \(String(describing: decision), privacy: .public)")
        // A stage on disk: still right, superseded, or now pointless?
        if let staged {
            switch UpdatePolicy.disposition(of: staged, current: currentVersion, latest: latest?.version) {
            case .keep:
                state = .ready(staged.release)
                if installAfterStage { installAfterStage = false; install() }
                return
            case .replace, .discard:
                installer.discard(staged)
                self.staged = nil
                if isDeferredToRestart { settings.pendingInstallVersion = nil }
            }
        }
        switch decision {
        case .upToDate:
            state = .upToDate(checkedAt: now)
        case let .skipped(release):
            // Manual checks surface a skipped version again so it can be un-skipped.
            state = userInitiated ? .available(release) : .upToDate(checkedAt: now)
        case let .available(release):
            state = .available(release)
            if UpdatePolicy.shouldStage(decision, mode: installMode) {
                stage(release)
            } else if !userInitiated {
                onUpdateFound?(release)
            }
        }
    }

    /// Download + verify into the staging area, then prompt (or install straight away
    /// when the user already asked for that). A background failure is quiet — the
    /// banner keeps offering the release with a "Download" that retries.
    private func stage(_ release: ReleaseInfo) {
        state = .downloading(release, progress: -1)
        snoozedUntil = nil
        reminderTimer?.invalidate()
        let installer = installer
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.reportProgress(fraction, for: release) }
        }
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await installer.stage(release, progress: onProgress)
                staged = result
                state = .ready(release)
                if settings.pendingInstallVersion != release.version
                    .description { settings.pendingInstallVersion = nil }
                if installAfterStage {
                    installAfterStage = false
                    install()
                } else {
                    onUpdateReady?(release)
                }
            } catch {
                let message = error.localizedDescription
                log.error("stage \(release.tagName, privacy: .public) failed: \(message, privacy: .public)")
                state = installAfterStage ? .failed(release, message: message) : .available(release)
                if installAfterStage { onInstallFailed?(message) }
                installAfterStage = false
            }
        }
    }

    // MARK: - User actions

    /// "Restart now": swap the staged bundle in and relaunch. On a release that isn't
    /// staged yet (a failed background download, a retry) this downloads first and
    /// installs as soon as it lands. Download-only installs open the release page.
    func install() {
        guard let release = state.offeredRelease, !state.isBusy else { return }
        if case let .downloadOnly(reason) = installMode {
            log.notice("install \(release.tagName, privacy: .public): download-only (\(reason, privacy: .public))")
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        guard case let .inPlace(bundleURL) = installMode else { return }
        guard let staged, staged.version == release.version else {
            installAfterStage = true
            stage(release)
            return
        }
        snoozedUntil = nil
        reminderTimer?.invalidate()
        state = .installing(release)
        let installer = installer
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await installer.install(staged, over: bundleURL)
            } catch {
                let message = error.localizedDescription
                log.error("install \(release.tagName, privacy: .public) failed: \(message, privacy: .public)")
                state = .failed(release, message: message)
                onInstallFailed?(message)
            }
        }
    }

    private func reportProgress(_ fraction: Double, for release: ReleaseInfo) {
        guard case .downloading = state else { return }
        state = .downloading(release, progress: fraction)
    }

    /// "Got it" on the post-update notes.
    func acknowledgeUpdate() { justUpdated = false }

    /// The running version's notes failed to load (offline at launch): try again
    /// when there is a fresh reason to (popover opened, wake).
    func retryCurrentReleaseNotes() {
        guard currentRelease == nil, currentVersion != nil, !isLoadingCurrentRelease else { return }
        Task { [weak self] in await self?.loadCurrentReleaseIfNeeded(latest: nil) }
    }

    /// "Later" on an offer, or closing a failure notice: hide it until the next
    /// due check. Closing a ready prompt is a "remind me later". Nothing is
    /// persisted — the version stays eligible.
    func dismiss() {
        switch state {
        case .available, .failed: state = .idle
        case .ready: remindLater()
        case .idle, .checking, .upToDate, .downloading, .installing: break
        }
    }

    /// "Skip this version": never offer this exact version again (a newer one still is).
    func skipOffered() {
        guard let release = state.offeredRelease, !state.isBusy else { return }
        settings.skippedUpdateVersion = release.version.description
        if let staged, staged.version == release.version {
            installer.discard(staged)
            self.staged = nil
        }
        if settings.pendingInstallVersion == release.version.description { settings.pendingInstallVersion = nil }
        snoozedUntil = nil
        reminderTimer?.invalidate()
        log.notice("skipped \(release.tagName, privacy: .public)")
        state = .idle
    }

    private static let firstCheckDelay: TimeInterval = 60
    private static let tickInterval: TimeInterval = 60 * 60
}
