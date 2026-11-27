import Foundation

/// Which Codex limit readings become history samples, for Codex's burn rate, pace and
/// sparkline. Codex limits arrive only with a Codex turn, so a sample is one *reading*
/// (one `observedAt`), never one 10-s scan. Samples are ordinary `UsageSample`s and
/// track the same window Claude's do: the session window, or weekly without one.
public enum CodexHistory {
    /// Same retention as Claude's `history.json`.
    public static let maxSamples = 4000

    /// The samples to append for `reading` as seen at `now`, oldest first; empty when
    /// it was already recorded. `history` must be oldest first (it is append-only).
    ///
    /// The reading is recorded as observed (a window that has reset *since* keeps its
    /// observed figure). Once the tracked window's reset passes with no newer reading,
    /// one reset point follows — 0% at the reset moment, in a new window so it never
    /// reads as a drop within the old one — and nothing more until the next reading.
    public static func samplesToRecord(
        reading: CodexLimitReading?,
        now: Date,
        history: [UsageSample],
    ) -> [UsageSample] {
        guard let reading,
              let observed = CodexLimits.snapshot(from: reading, now: reading.observedAt)
                  .sample(at: reading.observedAt)
        else { return [] }
        let lastRecorded = history.last?.timestamp ?? .distantPast
        var samples: [UsageSample] = []
        if observed.timestamp > lastRecorded { samples.append(observed) }
        if let point = resetPoint(after: observed, now: now),
           point.timestamp > max(lastRecorded, observed.timestamp) {
            samples.append(point)
        }
        return samples
    }

    /// `existing` plus `new`, keeping only the newest `cap` samples.
    public static func appending(_ new: [UsageSample], to existing: [UsageSample],
                                 cap: Int = maxSamples) -> [UsageSample] {
        guard !new.isEmpty else { return existing }
        return Array((existing + new).suffix(cap))
    }

    /// The tracked window at 0% from the moment its reset passed, or `nil` while it
    /// hasn't. A window that has reset loses its `resetsAt`: the next one's is unknown.
    private static func resetPoint(after observed: UsageSample, now: Date) -> UsageSample? {
        let trackedReset = observed.tracksSession ? observed.sessionResetsAt : observed.weeklyResetsAt
        guard let resetAt = trackedReset, resetAt <= now else { return nil }
        let weeklyReset = observed.weeklyResetsAt.map { $0 <= resetAt } ?? false
        return UsageSample(
            timestamp: resetAt,
            sessionUtilization: observed.tracksSession ? 0 : observed.sessionUtilization,
            sessionResetsAt: observed.tracksSession ? nil : observed.sessionResetsAt,
            weeklyUtilization: weeklyReset ? 0 : observed.weeklyUtilization,
            weeklyResetsAt: weeklyReset ? nil : observed.weeklyResetsAt,
        )
    }
}
