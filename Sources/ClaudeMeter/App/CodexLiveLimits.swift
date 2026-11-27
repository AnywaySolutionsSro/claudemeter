import ClaudeMeterCore
import Foundation
import OSLog

/// Polls live Codex limits from ChatGPT while signed in (every ~60 s, never more than
/// once per 30 s, backing off on 429 per `Retry-After`). Publishes the latest good
/// reading; a failed or unreadable fetch keeps it and only sets `statusNote` — never a
/// zero. `SessionMonitor` merges it with the transcript reading (`CodexLimitSource.pick`).
@MainActor
final class CodexLiveLimits: ObservableObject {
    @Published private(set) var reading: CodexLimitReading?
    @Published private(set) var statusNote: String?

    /// A new reading arrived (to rescan at once instead of waiting for the next tick).
    var onReading: (() -> Void)?

    let pollInterval: TimeInterval
    let minFetchInterval: TimeInterval

    private let client: ChatGPTUsageClient
    private var timer: Timer?
    private var lastAttempt: Date?
    private var backoffUntil: Date?
    private var isLoading = false
    /// After the usage endpoint refuses a freshly refreshed token. The login is kept:
    /// only a dead refresh grant signs out (`ChatGPTAccountStore`).
    private static let refusedBackoff: TimeInterval = 10 * 60

    init(client: ChatGPTUsageClient, pollInterval: TimeInterval = 60, minFetchInterval: TimeInterval = 30) {
        self.client = client
        self.pollInterval = pollInterval
        self.minFetchInterval = minFetchInterval
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer.tolerance = pollInterval / 10
        self.timer = timer
        Task { await refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Signed out: forget the reading so only transcripts feed Codex again.
    func clear() {
        stop()
        reading = nil
        statusNote = nil
        lastAttempt = nil
        backoffUntil = nil
    }

    func refresh() async {
        let now = Date()
        if let backoffUntil, now < backoffUntil { return }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < minFetchInterval { return }
        guard !isLoading else { return }
        isLoading = true
        lastAttempt = now
        defer { isLoading = false }

        do {
            let fresh = try await client.fetch(now: now)
            reading = fresh
            statusNote = nil
            backoffUntil = nil
            onReading?()
        } catch let ChatGPTError.rateLimited(retryAfter) {
            backoffUntil = Date().addingTimeInterval(RetryAfter.clamped(retryAfter))
            note(ChatGPTError.rateLimited(retryAfter: retryAfter))
        } catch ChatGPTError.superseded {
            // A newer grant took over mid-refresh; the next poll uses it. Not an error.
        } catch ChatGPTError.notSignedIn, ChatGPTError.sessionExpired {
            // Signed out (the store already dropped a dead grant and told the auth model).
            clear()
        } catch ChatGPTError.tokenRefused {
            ChatGPTAccountStore.log.notice("chatgpt: usage endpoint refused token — backing off 10 min")
            backoffUntil = Date().addingTimeInterval(Self.refusedBackoff)
            statusNote = ChatGPTError.tokenRefused.errorDescription
        } catch {
            note(error)
        }
    }

    private func note(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        ChatGPTAccountStore.log.notice("chatgpt: usage fetch failed: \(message, privacy: .public)")
        statusNote = message
    }
}
