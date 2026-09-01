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
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    /// Cached like `AuthModel.state`: the dropdown asks this once a second, and hitting the
    /// Keychain that often is what made macOS prompt repeatedly.
    @Published private(set) var hasKey: Bool

    private let client: CostClient
    private let keys: AdminKeyStore
    private var lastFetch: Date?
    private var timer: Timer?

    init(client: CostClient = CostClient(), keys: AdminKeyStore = AdminKeyStore()) {
        self.client = client
        self.keys = keys
        hasKey = keys.hasKey
        snapshot = Self.readCache()
    }

    /// Re-read after Settings saves or clears the key.
    func refreshKeyState() {
        hasKey = keys.hasKey
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(force: true) }
        }
        Task { await refresh(force: true) }
    }

    func refresh(force: Bool = false) async {
        guard hasKey else {
            snapshot = nil
            errorMessage = nil
            return
        }
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < Self.throttle { return }
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let fresh = try await client.fetchMonthToDate(now: Date())
            lastFetch = Date()
            snapshot = fresh
            errorMessage = nil
            Self.writeCache(fresh)
            deliverToWidget(fresh)
        } catch {
            // Keep showing the cached snapshot; surface why it's stale.
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Self.log.notice("api spend refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Forget everything when the key is removed, so no stale figures linger.
    func reset() {
        hasKey = false
        snapshot = nil
        errorMessage = nil
        lastFetch = nil
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Containers/com.jakubzak.claudemeter.widget")
            .appendingPathComponent("Data/Documents/api-spend.json")
    }

    private func deliverToWidget(_ snapshot: ApiSpendSnapshot) {
        let url = Self.widgetInboxURL()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try? data.write(to: url, options: .atomic)
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
