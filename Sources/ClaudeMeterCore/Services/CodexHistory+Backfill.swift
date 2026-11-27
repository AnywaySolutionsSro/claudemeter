import Foundation

/// Seeding `codex-history.json` from the `rate_limits` readings already in Codex's
/// transcripts, so the graph and pace have a past the day ClaudeMeter is installed
/// (or updated to a version that records Codex history).
public extension CodexHistory {
    /// Length assumed for the tracked window when telling where it began.
    private static let sessionWindowLength: TimeInterval = 5 * 3600
    private static let weeklyWindowLength: TimeInterval = 7 * 24 * 3600

    /// Whether `history` lacks the start of the window `reading` tracks: empty, or its
    /// oldest sample is newer than that window's start (unknown start: under a day of
    /// history). Backfilling is idempotent, so this only saves work.
    static func needsBackfill(history: [UsageSample], reading: CodexLimitReading?) -> Bool {
        guard let oldest = history.first else { return true }
        guard let reading,
              let observed = CodexLimits.snapshot(from: reading, now: reading.observedAt)
                  .sample(at: reading.observedAt)
        else { return false }
        let reset = observed.tracksSession ? observed.sessionResetsAt : observed.weeklyResetsAt
        guard let reset else {
            let newest = history.last?.timestamp ?? oldest.timestamp
            return newest.timeIntervalSince(oldest.timestamp) < 24 * 3600
        }
        let length = observed.tracksSession ? sessionWindowLength : weeklyWindowLength
        return oldest.timestamp > reset.addingTimeInterval(-length)
    }

    /// `history` merged with the samples `readings` yield under the usual rules (the
    /// session window else weekly, one sample per reading, unchanged figures spaced,
    /// one reset point per passed reset). Only the main `"codex"` limit is used when
    /// any reading carries it. A sample already in `history` at the same moment wins;
    /// the result is oldest first and capped like `appending`.
    static func backfilled(readings: [CodexLimitReading], now: Date, history: [UsageSample],
                           cap: Int = maxSamples) -> [UsageSample] {
        let main = readings.filter { $0.limitID == CodexLimits.primaryLimitID }
        let ordered = (main.isEmpty ? readings : main).sorted { $0.observedAt < $1.observedAt }
        var replayed: [UsageSample] = []
        for (index, reading) in ordered.enumerated() {
            // A reading's reset point is due only if it passed before the next reading.
            let until = index + 1 < ordered.count ? ordered[index + 1].observedAt : now
            replayed += samplesToRecord(reading: reading, now: until, history: replayed)
        }
        let known = Set(history.map(\.timestamp))
        let merged = (history + replayed.filter { !known.contains($0.timestamp) })
            .sorted { $0.timestamp < $1.timestamp }
        return Array(merged.suffix(cap))
    }
}
