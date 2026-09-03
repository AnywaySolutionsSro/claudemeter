import ClaudeMeterCore
import Foundation
import SwiftUI

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

    /// Fired once per refresh with every threshold crossing and reset detected in it, so
    /// the app can notify / run Shortcuts — and collapse several crossings into one.
    var onEvents: (([UsageEvent]) -> Void)?

    /// Fired when the OAuth session is irrecoverably dead (refresh token rejected, or the API
    /// keeps 401-ing a fresh token). The app flips to the signed-out UI instead of silently
    /// showing the stale cached reading forever.
    var onAuthExpired: (() -> Void)?

    let refreshInterval: TimeInterval
    let minFetchInterval: TimeInterval

    private let client: UsageClient
    private let decoder = UsageResponseDecoder()
    private var timer: Timer?
    private var lastAttempt: Date?
    private var backoffUntil: Date?
    /// Events only fire once we've seen a live reading this session, so the (possibly stale)
    /// on-disk cache never triggers spurious notifications on launch.
    private var hasLiveBaseline = false
    /// Consecutive auth-fatal refresh outcomes. A lone 401/403 on the undocumented endpoints
    /// can be a transient server flake, so the session is only declared dead — signing the
    /// user out and dropping their tokens — after two independent refresh cycles agree.
    private var consecutiveAuthFailures = 0

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

    /// Sign-out: forget everything, on disk too, so neither this run nor the next
    /// launch shows the previous account's reading or pace.
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
        history = []
        hasLiveBaseline = false
        consecutiveAuthFailures = 0
        ResponseCache.remove()
        UsageHistory.clear()
    }

    /// True once a reading has been fetched live in this run (the launch-time
    /// on-disk cache doesn't count).
    var hasLiveReading: Bool { hasLiveBaseline }

    /// The reading auto-resume may compare against to detect a refill: a live one,
    /// or a cached one young enough to belong to the current 5-hour window (an
    /// update relaunch, a quick restart). A days-old cache would make the first
    /// live fetch look like a refill and burn the refill cooldown for nothing.
    var snapshotForRefillDetection: UsageSnapshot? {
        guard let snapshot else { return nil }
        if hasLiveBaseline { return snapshot }
        return Date().timeIntervalSince(snapshot.fetchedAt) < Self.cachedBaselineMaxAge ? snapshot : nil
    }

    private static let cachedBaselineMaxAge: TimeInterval = 5 * 60 * 60

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
            consecutiveAuthFailures = 0

            if let sample = fresh.sample(at: now) {
                history = UsageHistory.append(sample, to: history)
            }
            recompute(now: now)
            if hasLiveBaseline {
                detectEvents(previous: previous, current: fresh, now: now)
            }
            hasLiveBaseline = true
        } catch let UsageError.rateLimited(retryAfter) {
            backoffUntil = Date().addingTimeInterval(retryAfter ?? 120)
            present(UsageError.rateLimited(retryAfter: retryAfter).errorDescription ?? "Rate limited.")
        } catch UsageError.sessionExpired, AuthError.notAuthenticated {
            consecutiveAuthFailures += 1
            if consecutiveAuthFailures >= 2 {
                // Confirmed dead. Drop the stale reading here too (not only via the app's
                // signed-out wiring) so no path can keep rendering it.
                snapshot = nil
                lastUpdated = nil
                errorMessage = UsageError.sessionExpired.errorDescription
                statusNote = nil
                onAuthExpired?()
            } else {
                present(UsageError.sessionExpired.errorDescription ?? "Session expired.")
            }
        } catch {
            present((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func recompute(now: Date) {
        burnEstimate = BurnRate.estimate(samples: history, now: now)
        paceRatio = UsageStats.paceRatio(
            current: burnEstimate?.percentPerHour ?? 0,
            typical: UsageStats.typicalPercentPerHour(samples: history),
        )
    }

    /// Emit threshold/reset events — only once a real prior reading exists (so a cold launch
    /// at already-high usage doesn't fire spurious nudges).
    private func detectEvents(previous: UsageSnapshot?, current: UsageSnapshot, now: Date) {
        guard let previous, let bucket = current.fiveHour else { return }
        var events: [UsageEvent] = []

        if UsageStats.didRefill(
            previousUtilization: previous.fiveHour?.utilization,
            currentUtilization: bucket.utilization,
        ) {
            events.append(.reset(nextResetsAt: bucket.resetsAt))
        }

        let crossed = UsageStats.crossedThresholds(
            previous: previous.fiveHour?.utilization,
            current: bucket.utilization,
            thresholds: [80, 90, 100],
        )
        for threshold in crossed {
            events.append(.crossedThreshold(
                threshold,
                remaining: bucket.percentRemaining,
                etaToReset: bucket.timeUntilReset(now: now),
            ))
        }
        if !events.isEmpty { onEvents?(events) }
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
