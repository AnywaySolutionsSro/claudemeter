import AppKit
import ClaudeMeterCore
import Foundation
import os

/// Where the updater is right now; drives the dropdown banner and Settings.
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case available(ReleaseInfo)
    /// `progress` in 0...1, or -1 when the size is unknown.
    case downloading(ReleaseInfo, progress: Double)
    case installing(ReleaseInfo)
    case failed(ReleaseInfo?, message: String)

    var offeredRelease: ReleaseInfo? {
        switch self {
        case let .available(release), let .downloading(release, _), let .installing(release): release
        case let .failed(release, _): release
        case .idle, .checking, .upToDate: nil
        }
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing: true
        default: false
        }
    }
}

/// Checks GitHub once a day for a newer release, offers it, and — on the user's
/// say-so — downloads, verifies and installs it via `UpdateInstaller`.
///
/// Cadence: a first check ~1 min after launch (only if one is due), then an hourly
/// tick that runs a real check only when `UpdatePolicy.isCheckDue` says so, plus a
/// wake-from-sleep hook. "Later" hides the offer until the next due check;
/// "Skip this version" persists and suppresses that one version for good.
@MainActor
final class UpdateService: ObservableObject {
    @Published private(set) var state: UpdateState = .idle

    let currentVersion: AppVersion?
    let installMode: InstallMode

    /// Invoked when a *background* check finds an update (the dropdown handles
    /// user-initiated checks itself).
    var onUpdateFound: ((ReleaseInfo) -> Void)?
    /// Invoked when an install attempt fails, with a user-facing message.
    var onInstallFailed: ((String) -> Void)?

    private let settings: Settings
    private let client: GitHubReleaseClient
    private let installer: UpdateInstaller
    private let log = Logger(subsystem: "com.jakubzak.claudemeter", category: "updater")
    private var timer: Timer?
    private var checkTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?

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

    func start() {
        let version = currentVersion?.description ?? "unversioned"
        log
            .notice(
                "updater start: running \(version, privacy: .public), mode \(String(describing: self.installMode), privacy: .public)",
            )
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstCheckDelay) { [weak self] in
            self?.checkIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    /// Runs a background check when the daily interval has elapsed (also called on wake).
    func checkIfDue(now: Date = Date()) {
        guard settings.autoUpdateCheckEnabled, !state.isBusy else { return }
        guard UpdatePolicy.isCheckDue(lastCheck: settings.lastUpdateCheck, now: now) else { return }
        check(userInitiated: false)
    }

    /// "Check now" from Settings — ignores the interval and the auto-check switch.
    func checkNow() { check(userInitiated: true) }

    private func check(userInitiated: Bool) {
        guard !state.isBusy else { return }
        state = .checking
        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let latest = try await client.fetchLatest()
                apply(latest: latest, userInitiated: userInitiated)
            } catch {
                log.error("check failed: \(error.localizedDescription, privacy: .public)")
                // A background failure is silent (retry next tick); a manual one is shown.
                state = userInitiated ? .failed(nil, message: error.localizedDescription) : .idle
            }
        }
    }

    private func apply(latest: ReleaseInfo?, userInitiated: Bool) {
        let now = Date()
        settings.lastUpdateCheck = now
        let skipped = settings.skippedUpdateVersion.flatMap(AppVersion.init)
        let decision = UpdatePolicy.decide(current: currentVersion, latest: latest, skipped: skipped)
        let latestTag = latest?.tagName ?? "none"
        log.notice("check: latest \(latestTag, privacy: .public) -> \(String(describing: decision), privacy: .public)")
        switch decision {
        case .upToDate:
            state = .upToDate(checkedAt: now)
        case let .skipped(release):
            // Manual checks surface a skipped version again so it can be un-skipped.
            state = userInitiated ? .available(release) : .upToDate(checkedAt: now)
        case let .available(release):
            state = .available(release)
            if !userInitiated { onUpdateFound?(release) }
        }
    }

    // MARK: - User actions

    /// Download + verify + swap + relaunch; or open the release page when in-place
    /// install isn't possible for this install location.
    func install() {
        guard let release = state.offeredRelease, !state.isBusy else { return }
        if case let .downloadOnly(reason) = installMode {
            log.notice("install \(release.tagName, privacy: .public): download-only (\(reason, privacy: .public))")
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        guard case let .inPlace(bundleURL) = installMode else { return }
        state = .downloading(release, progress: -1)
        let installer = installer
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.reportProgress(fraction, for: release) }
        }
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                let staged = try await installer.stage(release, progress: onProgress)
                state = .installing(release)
                try await installer.install(staged: staged, over: bundleURL)
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

    /// "Later" on an offer, or closing a failure notice: hide it until the next
    /// due check. Nothing is persisted — the version stays eligible.
    func dismiss() {
        switch state {
        case .available, .failed: state = .idle
        case .idle, .checking, .upToDate, .downloading, .installing: break
        }
    }

    /// "Skip this version": never offer this exact version again (a newer one still is).
    func skipOffered() {
        guard let release = state.offeredRelease, !state.isBusy else { return }
        settings.skippedUpdateVersion = release.version.description
        log.notice("skipped \(release.tagName, privacy: .public)")
        state = .idle
    }

    private static let firstCheckDelay: TimeInterval = 60
    private static let tickInterval: TimeInterval = 60 * 60
}
