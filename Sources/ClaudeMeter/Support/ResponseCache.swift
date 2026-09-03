import Foundation

/// Persists the most recent successful usage response to Application Support, and reads it
/// back on launch. This lets the app show your last reading instantly — before the first
/// network call, and while rate-limited (HTTP 429) — instead of an empty state.
///
/// The file contains only usage numbers (no tokens/secrets) and is safe to delete.
enum ResponseCache {
    static func write(_ data: Data) {
        guard let url = fileURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try? data.write(to: url)
    }

    static func read() -> Data? {
        guard let url = fileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Forget the last reading (sign-out): the next launch must not show another
    /// account's numbers.
    static func remove() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func modificationDate() -> Date? {
        guard let url = fileURL else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static var fileURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ClaudeMeter", isDirectory: true)
            .appendingPathComponent("last-usage.json")
    }
}
