import ClaudeMeterCore
import Combine
import Foundation
import OSLog
import WidgetKit

/// Publishes organization API spend to the dropdown and delivers it to the widget.
///
/// Mirrors `UsageStore`, but polls far less often: the Cost API is daily-granularity and
/// trails real usage by ~5 minutes, so anything faster is wasted traffic.
@MainActor
final class ApiSpendStore: ObservableObject {
    private static let log = Logger(subsystem: "com.jakubzak.claudemeter", category: "apispend")

    /// Minimum gap between fetches triggered by opening the dropdown.
    private static let throttle: TimeInterval = 5 * 60
    /// Background refresh cadence.
    private static let tick: TimeInterval = 15 * 60

    @Published private(set) var snapshot: ApiSpendSnapshot?
    /// A hard error with no data behind it.
    @Published private(set) var errorMessage: String?
    /// A note explaining why the figures below it are stale — the data is still shown.
    @Published private(set) var statusNote: String?
    /// When the displayed figures were actually fetched. Never leave this implicit: a
    /// cached snapshot rendered without it reads as current.
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isLoading = false
    /// Cached like `AuthModel.state`: the dropdown asks this once a second, and hitting the
    /// Keychain that often is what made macOS prompt repeatedly.
    @Published private(set) var hasKey: Bool

    private let client: CostClient
    private let keys: AdminKeyStore
    /// Timestamp of the last *attempt*, not the last success — a failing fetch must still
    /// throttle, or every dropdown open re-runs the whole request while broken.
    private var lastAttempt: Date?
    private var backoffUntil: Date?
    private var timer: Timer?

    init(client: CostClient = CostClient(), keys: AdminKeyStore = AdminKeyStore()) {
        self.client = client
        self.keys = keys
        hasKey = keys.hasKey
        snapshot = Self.readCache()
        lastUpdated = snapshot?.fetchedAt
    }

    /// Re-read after Settings saves or clears the key.
    func refreshKeyState() {
        let present = keys.hasKey
        if hasKey != present { hasKey = present }
    }

    /// Invalidate the tick — the store outlives the app today, but a second instance
    /// would otherwise leak a timer into the run loop.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(force: true) }
        }
        Task { await refresh(force: true) }
    }

    func refresh(force: Bool = false) async {
        guard hasKey else {
            // Full reset: clearing memory alone would leave the disk cache and the widget
            // file showing figures for a key that is no longer there.
            if snapshot != nil || errorMessage != nil { reset() }
            return
        }

        let now = Date()
        if let backoffUntil, now < backoffUntil { return }
        if !force, let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.throttle { return }
        guard !isLoading else { return }

        isLoading = true
        lastAttempt = now
        defer { isLoading = false }

        do {
            let fresh = try await client.fetchMonthToDate(now: Date())
            snapshot = fresh
            lastUpdated = fresh.fetchedAt
            errorMessage = nil
            statusNote = nil
            backoffUntil = nil
            Self.writeCache(fresh)
            deliverToWidget(fresh)
        } catch let CostError.rateLimited(retryAfter) {
            backoffUntil = Date().addingTimeInterval(retryAfter ?? 120)
            present(CostError.rateLimited(retryAfter: retryAfter))
        } catch {
            present(error)
        }
    }

    /// Distinguishes "no data at all" from "stale data shown below", the way `UsageStore`
    /// does. A failed refresh must never silently overwrite a good reading.
    private func present(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if snapshot == nil {
            errorMessage = message
            statusNote = nil
        } else {
            statusNote = message
            errorMessage = nil
        }
        Self.log.notice("api spend refresh failed: \(Self.label(for: error), privacy: .public)")
    }

    /// A closed vocabulary — never interpolate a foreign error into a persisted log line,
    /// where a URL or header could ride along in its `userInfo`.
    private static func label(for error: Error) -> String {
        switch error as? CostError {
        case .keyUnreadable: "keyUnreadable"
        case .invalidAdminKey: "invalidAdminKey"
        case .notAnOrganization: "notAnOrganization"
        case .rateLimited: "rateLimited"
        case let .http(code): "http(\(code))"
        case .network: "network"
        case .unreadableReport: "unreadableReport"
        case nil: "other"
        }
    }

    /// Forget everything when the key is removed, so no stale figures linger.
    func reset() {
        hasKey = false
        snapshot = nil
        errorMessage = nil
        statusNote = nil
        lastUpdated = nil
        lastAttempt = nil
        backoffUntil = nil
        try? FileManager.default.removeItem(at: Self.cacheURL)
        try? FileManager.default.removeItem(at: Self.widgetInboxURL())
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Widget delivery

    /// A sandboxed widget cannot read the non-sandboxed app's App Group container, so the
    /// snapshot is written into the widget's **own** container — the same trick
    /// `SessionMonitor` uses. Kept as a separate file from `snapshot.json` because the two
    /// producers run on different cadences and would otherwise race.
    nonisolated static func widgetInboxURL() -> URL {
        // Reuse SessionMonitor's constant: the appex's bundle ID is
        // `…claudemeter.ClaudeMeterWidget`, and hardcoding a guess here wrote the snapshot
        // into a directory the app happily created and the widget never reads.
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/\(SessionMonitor.widgetBundleID)/Data/Documents",
                isDirectory: true,
            )
            .appendingPathComponent("api-spend.json")
    }

    private func deliverToWidget(_ snapshot: ApiSpendSnapshot) {
        let url = Self.widgetInboxURL()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // Silent failure here is how the wrong-container bug hid for a whole release.
            Self.log.notice("widget delivery failed: \(url.path, privacy: .public)")
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Disk cache

    private static var cacheURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeMeter", isDirectory: true)
            .appendingPathComponent("last-api-spend.json")
    }

    private static func readCache() -> ApiSpendSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(ApiSpendSnapshot.self, from: data)
    }

    private static func writeCache(_ snapshot: ApiSpendSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try? data.write(to: cacheURL, options: .atomic)
    }
}
