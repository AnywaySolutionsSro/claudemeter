import Foundation

/// Persists the set of armed session UUIDs and shuttles widget commands.
/// Mirrors `SnapshotStore`: a small `Codable` payload written atomically.
public struct ArmedSessionsStore: Sendable {
    private struct Container: Codable { let sessionIDs: [String] }

    public init() {}

    // MARK: Armed set

    public func encode(_ ids: Set<String>) throws -> Data {
        try JSONEncoder().encode(Container(sessionIDs: ids.sorted()))
    }

    public func decode(_ data: Data) throws -> Set<String> {
        try Set(JSONDecoder().decode(Container.self, from: data).sessionIDs)
    }

    public func write(_ ids: Set<String>, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try encode(ids).write(to: url, options: .atomic)
    }

    public func read(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decode(data)) ?? []
    }

    // MARK: Widget command queue

    public func appendCommand(_ command: WidgetCommand, to url: URL) throws {
        var batch = readBatch(at: url)
        batch.commands.append(command)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try JSONEncoder().encode(batch).write(to: url, options: .atomic)
    }

    /// Reads all pending commands and removes the file (best-effort).
    public func drainCommands(at url: URL) -> [WidgetCommand] {
        let batch = readBatch(at: url)
        try? FileManager.default.removeItem(at: url)
        return batch.commands
    }

    /// Reads pending commands WITHOUT removing them. Used by the widget to render
    /// the user's tap optimistically before the app drains and applies it.
    public func peekCommands(at url: URL) -> [WidgetCommand] {
        readBatch(at: url).commands
    }

    private func readBatch(at url: URL) -> WidgetCommandBatch {
        guard let data = try? Data(contentsOf: url),
              let batch = try? JSONDecoder().decode(WidgetCommandBatch.self, from: data)
        else { return WidgetCommandBatch(commands: []) }
        return batch
    }
}
