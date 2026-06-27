import Foundation
import SwiftUI
import ClaudeMeterCore

/// Observable view-model that polls the usage API and publishes the latest snapshot.
///
/// To stay well under the endpoint's rate limit it:
///  • throttles network calls to at most once per `minFetchInterval` (popover-opens reuse
///    the cached reading when it's fresh);
///  • backs off after an HTTP 429, honouring `Retry-After`;
///  • seeds itself from the on-disk cache so a reading shows instantly on launch.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    /// Hard error, shown only when there is no reading to display.
    @Published private(set) var errorMessage: String?
    /// Soft, non-alarming note shown alongside an existing reading (e.g. rate-limited).
    @Published private(set) var statusNote: String?
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?

    let refreshInterval: TimeInterval
    let minFetchInterval: TimeInterval

    private let client: UsageClient
    private let decoder = UsageResponseDecoder()
    private var timer: Timer?
    private var lastAttempt: Date?
    private var backoffUntil: Date?

    init(client: UsageClient, refreshInterval: TimeInterval = 300, minFetchInterval: TimeInterval = 30) {
        self.client = client
        self.refreshInterval = refreshInterval
        self.minFetchInterval = minFetchInterval
        loadCachedSnapshot()
    }

    func start() {
        guard timer == nil else { return }
        Task { await refresh(force: true) }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Clear all state on sign-out so no stale reading lingers.
    func clear() {
        stop()
        snapshot = nil
        lastUpdated = nil
        errorMessage = nil
        statusNote = nil
        lastAttempt = nil
        backoffUntil = nil
    }

    /// Fetch the latest usage. Skips the network when a recent reading already exists, unless
    /// `force` is set (the manual Refresh button). Backoff after a 429 is always respected.
    func refresh(force: Bool = false) async {
        let now = Date()

        if let backoffUntil, now < backoffUntil { return }
        if !force, let lastAttempt, now.timeIntervalSince(lastAttempt) < minFetchInterval { return }
        guard !isLoading else { return }

        isLoading = true
        lastAttempt = now
        defer { isLoading = false }

        do {
            snapshot = try await client.fetch()
            lastUpdated = Date()
            errorMessage = nil
            statusNote = nil
            backoffUntil = nil
        } catch UsageError.rateLimited(let retryAfter) {
            backoffUntil = Date().addingTimeInterval(retryAfter ?? 120)
            present(UsageError.rateLimited(retryAfter: retryAfter).errorDescription ?? "Rate limited.")
        } catch {
            present((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func present(_ message: String) {
        // Keep showing data if we have it; only escalate to a hard error when we have nothing.
        if snapshot == nil {
            errorMessage = message
            statusNote = nil
        } else {
            statusNote = message
            errorMessage = nil
        }
    }

    private func loadCachedSnapshot() {
        guard let data = ResponseCache.read() else { return }
        let date = ResponseCache.modificationDate() ?? Date()
        if let cached = try? decoder.decode(data, fetchedAt: date) {
            snapshot = cached
            lastUpdated = date
        }
    }
}
