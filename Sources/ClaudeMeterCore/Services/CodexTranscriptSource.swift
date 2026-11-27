import Foundation

/// Discovers Codex transcripts, plus the ids of the Claude threads Codex imported
/// (which are not Codex work and must be skipped).
public protocol CodexTranscriptDiscovering: TranscriptDiscovering {
    /// Thread ids listed in `~/.codex/external_agent_session_imports.json`.
    func importedIDs() -> Set<String>
}

/// Filesystem discovery of Codex transcripts under `~/.codex`:
///
/// - `sessions/YYYY/MM/DD/rollout-<timestamp>-<sessionId>.jsonl`, walked recursively.
///   The id is `session_meta.payload.id` (first line), else the filename's uuid suffix.
///   Origin comes from `session_meta.payload.originator` (`Codex Desktop` → desktop).
/// - Titles from `session_index.jsonl` (`id`, `thread_name`; the last entry per id wins).
///
/// Never touches `auth.json`. A missing home or file contributes nothing.
/// `@unchecked Sendable`: `FileManager` is only used for read-only enumeration.
public struct CodexTranscriptSource: CodexTranscriptDiscovering, @unchecked Sendable {
    private let codexHome: URL
    private let fileManager: FileManager

    public init(codexHome: URL = CodexTranscriptSource.defaultHome, fileManager: FileManager = .default) {
        self.codexHome = codexHome
        self.fileManager = fileManager
    }

    /// `~/.codex`.
    public static var defaultHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private static let uuidLength = 36

    public func discover() -> [TranscriptRef] {
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
        ) else {
            return []
        }
        let titles = threadTitles()
        var refs: [TranscriptRef] = []
        for case let url as URL in enumerator where isRollout(url) {
            refs.append(makeRef(url: url, titles: titles))
        }
        return refs
    }

    public func lines(of ref: TranscriptRef) -> [String] {
        TranscriptFileReader.lines(of: ref.url)
    }

    public func chunk(of ref: TranscriptRef, fromByteOffset offset: Int64) -> TranscriptChunk? {
        TranscriptFileReader.chunk(of: ref.url, fromByteOffset: offset)
    }

    public func importedIDs() -> Set<String> {
        let url = codexHome.appendingPathComponent("external_agent_session_imports.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = root["records"] as? [[String: Any]]
        else { return [] }
        return Set(records.compactMap { $0["imported_thread_id"] as? String })
    }

    // MARK: - Helpers

    private func isRollout(_ url: URL) -> Bool {
        url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-")
    }

    private func makeRef(url: URL, titles: [String: String]) -> TranscriptRef {
        let meta = sessionMeta(of: url)
        let id = meta.id ?? fallbackID(of: url)
        let isDesktop = meta.originator?.lowercased().contains("desktop") == true
        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date(timeIntervalSince1970: 0)
        return TranscriptRef(
            id: id, url: url, origin: isDesktop ? .codexDesktop : .codexCLI,
            title: titles[id], modifiedAt: modifiedAt,
        )
    }

    /// `id` / `originator` from the first line when it is a `session_meta` entry.
    private func sessionMeta(of url: URL) -> (id: String?, originator: String?) {
        guard let line = TranscriptFileReader.firstLine(of: url),
              case let .meta(id, _, originator, _)? = CodexTranscriptParser.parse(line)?.event
        else { return (nil, nil) }
        return (id, originator)
    }

    /// `rollout-2026-11-26T22-57-51-<uuid>` → `<uuid>`; the whole stem if it is shorter.
    private func fallbackID(of url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.count > Self.uuidLength + 1 else { return stem }
        return String(stem.suffix(Self.uuidLength))
    }

    private func threadTitles() -> [String: String] {
        let url = codexHome.appendingPathComponent("session_index.jsonl")
        var titles: [String: String] = [:]
        for line in TranscriptFileReader.lines(of: url) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? String,
                  let name = object["thread_name"] as? String, !name.isEmpty
            else { continue }
            titles[id] = name
        }
        return titles
    }
}
