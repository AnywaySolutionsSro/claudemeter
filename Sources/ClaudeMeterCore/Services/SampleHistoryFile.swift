import Foundation

/// A JSON file of `UsageSample`s, by default in Application Support/ClaudeMeter.
/// Decoding is all-or-nothing and tolerant: a missing or unreadable file is an empty
/// history.
public struct SampleHistoryFile: Sendable {
    public let name: String
    /// The folder holding the file; `nil` means Application Support/ClaudeMeter.
    private let directory: URL?

    public init(name: String, directory: URL? = nil) {
        self.name = name
        self.directory = directory
    }

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

    public func load() -> [UsageSample] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode([UsageSample].self, from: data)) ?? []
    }

    public func save(_ samples: [UsageSample]) {
        guard let url, let data = try? Self.encoder.encode(samples) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try? data.write(to: url)
    }

    public func remove() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private var url: URL? {
        if let directory { return directory.appendingPathComponent(name) }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ClaudeMeter", isDirectory: true)
            .appendingPathComponent(name)
    }
}
