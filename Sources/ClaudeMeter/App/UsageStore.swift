import Foundation
import SwiftUI
import ClaudeMeterCore

/// Events worth reacting to (notifications, Shortcut hooks), emitted on each refresh.
enum UsageEvent {
    case crossedThreshold(Double, remaining: Double, etaToReset: TimeInterval?)
    case reset(nextResetsAt: Date?)
}

/// Observable view-model that polls the usage API and publishes the latest snapshot plus
/// derived state (history, burn rate, pace). See class comment in the original for the
/// throttle/backoff/cache rationale.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusNote: String?
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?

    @Published private(set) var history: [UsageSample] = []
    @Published private(set) var burnEstimate: BurnEstimate?
    @Published private(set) var paceRatio: Double?

    /// Fired for threshold crossings and resets so the app can notify / run Shortcuts.
    var onEvent: ((UsageEvent) -> Void)?

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
        history = UsageHistory.load()
        recompute(now: Date())
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

    func clear() {
        stop()
        snapshot = nil
        lastUpdated = nil
        errorMessage = nil
        statusNote = nil
        lastAttempt = nil
        backoffUntil = nil
        burnEstimate = nil
        paceRatio = nil
    }

    func refresh(force: Bool = false) async {
        let now = Date()
        if let backoffUntil, now < backoffUntil { return }
        if !force, let lastAttempt, now.timeIntervalSince(lastAttempt) < minFetchInterval { return }
        guard !isLoading else { return }

        isLoading = true
        lastAttempt = now
        defer { isLoading = false }

        do {
            let fresh = try await client.fetch()
            let previous = snapshot
            snapshot = fresh
            lastUpdated = Date()
            errorMessage = nil
            statusNote = nil
            backoffUntil = nil

            if let sample = fresh.sample(at: now) {
                history = UsageHistory.append(sample, to: history)
            }
            recompute(now: now)
            detectEvents(previous: previous, current: fresh, now: now)
        } catch UsageError.rateLimited(let retryAfter) {
            backoffUntil = Date().addingTimeInterval(retryAfter ?? 120)
            present(UsageError.rateLimited(retryAfter: retryAfter).errorDescription ?? "Rate limited.")
        } catch {
            present((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func recompute(now: Date) {
        burnEstimate = BurnRate.estimate(samples: history, now: now)
        paceRatio = UsageStats.paceRatio(
            current: burnEstimate?.percentPerHour ?? 0,
            typical: UsageStats.typicalPercentPerHour(samples: history)
        )
    }

    /// Emit threshold/reset events — only once a real prior reading exists (so a cold launch
    /// at already-high usage doesn't fire spurious nudges).
    private func detectEvents(previous: UsageSnapshot?, current: UsageSnapshot, now: Date) {
        guard let previous, let bucket = current.fiveHour else { return }

        if UsageStats.didReset(previousResetsAt: previous.fiveHour?.resetsAt, currentResetsAt: bucket.resetsAt) {
            onEvent?(.reset(nextResetsAt: bucket.resetsAt))
        }

        let crossed = UsageStats.crossedThresholds(
            previous: previous.fiveHour?.utilization,
            current: bucket.utilization,
            thresholds: [80, 90, 100]
        )
        for threshold in crossed {
            onEvent?(.crossedThreshold(
                threshold,
                remaining: bucket.percentRemaining,
                etaToReset: bucket.timeUntilReset(now: now)
            ))
        }
    }

    private func present(_ message: String) {
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
