import ClaudeMeterCore
import Foundation

/// Persists a rolling window of Claude `UsageSample`s to `history.json`, powering
/// burn-rate, sparklines, averages, and weekly stats across launches.
enum UsageHistory {
    private static let maxSamples = 4000 // ~2 weeks at 5-minute polling
    private static let file = SampleHistoryFile(name: "history.json")

    static func load() -> [UsageSample] { file.load() }

    /// Append a sample, trim to the cap, persist, and return the new history.
    static func append(_ sample: UsageSample, to existing: [UsageSample]) -> [UsageSample] {
        var all = existing
        all.append(sample)
        if all.count > maxSamples { all.removeFirst(all.count - maxSamples) }
        file.save(all)
        return all
    }

    /// Drop all samples (sign-out): burn rate and pace must not carry over between accounts.
    static func clear() { file.remove() }
}

/// Codex's own history, in `codex-history.json` beside Claude's. Never mixed with
/// `history.json`: both tools have a "Weekly" window, and a Claude sign-out must not
/// erase Codex's pace (Codex has no sign-in of its own).
enum CodexUsageHistory {
    private static let file = SampleHistoryFile(name: "codex-history.json")

    static func load() -> [UsageSample] { file.load() }

    /// Append the samples `CodexHistory` chose, persisting only when there are any.
    static func append(_ samples: [UsageSample], to existing: [UsageSample]) -> [UsageSample] {
        guard !samples.isEmpty else { return existing }
        let all = CodexHistory.appending(samples, to: existing)
        file.save(all)
        return all
    }
}
