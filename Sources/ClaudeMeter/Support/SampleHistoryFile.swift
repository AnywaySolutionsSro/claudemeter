import ClaudeMeterCore
import Foundation

/// A JSON file of `UsageSample`s in Application Support/ClaudeMeter. Decoding is
/// all-or-nothing and tolerant: a missing or unreadable file is an empty history.
struct SampleHistoryFile {
    let name: String

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

    func load() -> [UsageSample] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode([UsageSample].self, from: data)) ?? []
    }

    func save(_ samples: [UsageSample]) {
        guard let url, let data = try? Self.encoder.encode(samples) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try? data.write(to: url)
    }

    func remove() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private var url: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ClaudeMeter", isDirectory: true)
            .appendingPathComponent(name)
    }
}
