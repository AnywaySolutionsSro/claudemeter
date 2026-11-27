import Foundation
import Synchronization

/// The file reads `CodexTranscriptSource.discover` makes, injectable so tests can
/// count them.
struct CodexSourceReader: Sendable {
    /// The first line of a rollout (its `session_meta`), or `nil`.
    let firstLine: @Sendable (URL) -> String?
    /// Every line of `session_index.jsonl`.
    let lines: @Sendable (URL) -> [String]

    static let live = CodexSourceReader(
        firstLine: { TranscriptFileReader.firstLine(of: $0) },
        lines: { TranscriptFileReader.lines(of: $0) },
    )
}

/// What `discover` remembers between 10-s scans, so an unchanged file is not
/// re-read: a rollout's `session_meta` (first line, ~28 KB, never rewritten) per
/// path, and the parsed `session_index.jsonl` keyed by its mtime and size.
final class CodexSourceCache: Sendable {
    struct Meta: Equatable {
        let id: String?
        let originator: String?
    }

    struct IndexStamp: Equatable {
        let modifiedAt: Date
        let size: Int
    }

    private struct State {
        var metas: [String: Meta] = [:]
        var index: (stamp: IndexStamp, titles: [String: String])?
    }

    private let state = Mutex(State())

    /// The cached meta for `path`, or the one `load` returns — cached only once a
    /// `session_meta` line parsed, since a rollout's first line may not be written yet.
    func meta(forPath path: String, load: () -> Meta?) -> Meta? {
        if let cached = state.withLock({ $0.metas[path] }) { return cached }
        guard let loaded = load() else { return nil }
        state.withLock { $0.metas[path] = loaded }
        return loaded
    }

    /// Drops metas for rollouts that no longer exist, so the cache can't grow forever.
    func retainMetas(forPaths paths: Set<String>) {
        state.withLock { $0.metas = $0.metas.filter { paths.contains($0.key) } }
    }

    /// The cached titles when `stamp` matches, else the ones `load` returns.
    func titles(stamp: IndexStamp?, load: () -> [String: String]) -> [String: String] {
        guard let stamp else {
            state.withLock { $0.index = nil }
            return [:]
        }
        if let cached = state.withLock({ $0.index }), cached.stamp == stamp { return cached.titles }
        let loaded = load()
        state.withLock { $0.index = (stamp, loaded) }
        return loaded
    }
}
