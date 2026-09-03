import ClaudeMeterCore
import Foundation

/// Persists a rolling window of `UsageSample`s to Application Support, powering burn-rate,
/// sparklines, averages, and weekly stats across launches.
enum UsageHistory {
    private static let maxSamples = 4000 // ~2 weeks at 5-minute polling

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    static func load() -> [UsageSample] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([UsageSample].self, from: data)) ?? []
    }

    /// Append a sample, trim to the cap, persist, and return the new history.
    static func append(_ sample: UsageSample, to existing: [UsageSample]) -> [UsageSample] {
        var all = existing
        all.append(sample)
        if all.count > maxSamples { all.removeFirst(all.count - maxSamples) }
        save(all)
        return all
    }

    /// Drop all samples (sign-out): burn rate and pace must not carry over between accounts.
    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func save(_ samples: [UsageSample]) {
        guard let url = fileURL, let data = try? encoder.encode(samples) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try? data.write(to: url)
    }

    private static var fileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ClaudeMeter", isDirectory: true)
            .appendingPathComponent("history.json")
    }
}
