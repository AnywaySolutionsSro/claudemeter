import Foundation

/// Persists a `SessionSnapshot` as JSON so the widget extension can read what the
/// main app last computed. Encoding/decoding is pure and testable; callers supply
/// the destination URL (the app writes to the shared App Group container).
public struct SnapshotStore: Sendable {
    /// App Group identifier shared between the app and its widget extension.
    public static let appGroupID = "group.com.jakubzak.claudemeter"

    public init() {}

    public func encode(_ snapshot: SessionSnapshot) throws -> Data {
        try JSONEncoder().encode(snapshot)
    }

    public func decode(_ data: Data) throws -> SessionSnapshot {
        try JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    /// Atomically write the snapshot, creating the parent directory if needed.
    public func write(_ snapshot: SessionSnapshot, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encode(snapshot).write(to: url, options: .atomic)
    }

    /// Read a snapshot, returning `nil` on any failure (missing/corrupt file).
    public func read(from url: URL) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }
}
