import Foundation

/// A reference to a single Claude Code transcript file on disk.
///
/// The `id` is the session identifier, which equals the transcript filename
/// stem (the filename with the `.jsonl` extension removed).
public struct TranscriptRef: Sendable, Equatable, Identifiable {
    /// Session id = transcript filename stem (no `.jsonl`).
    public let id: String
    /// On-disk location of the transcript.
    public let url: URL
    /// Where the transcript came from (CLI vs. desktop app).
    public let origin: SessionOrigin
    /// Optional human-readable title (not derived here; always `nil` for now).
    public let title: String?
    /// File content modification date.
    public let modifiedAt: Date
    /// For a subagent transcript (`…/<sessionId>/subagents/agent-*.jsonl`), the
    /// parent session id its usage belongs to; `nil` for top-level transcripts.
    public let parentID: String?

    public init(id: String, url: URL, origin: SessionOrigin, title: String?, modifiedAt: Date,
                parentID: String? = nil) {
        self.id = id
        self.url = url
        self.origin = origin
        self.title = title
        self.modifiedAt = modifiedAt
        self.parentID = parentID
    }
}

/// Complete lines read from a transcript starting at a byte offset, plus the
/// offset of the first byte after the last consumed newline (the resume point).
public struct TranscriptChunk: Equatable, Sendable {
    public let lines: [String]
    public let endOffset: Int64

    public init(lines: [String], endOffset: Int64) {
        self.lines = lines
        self.endOffset = endOffset
    }
}

/// Discovers transcript files and reads their raw lines.
public protocol TranscriptDiscovering: Sendable {
    /// All discovered transcripts: CLI refs first, then desktop refs.
    func discover() -> [TranscriptRef]
    /// Raw lines of a transcript; `[]` on any read failure.
    func lines(of ref: TranscriptRef) -> [String]
    /// Complete lines appended at/after `fromByteOffset` (a partial trailing line
    /// is left unconsumed). `nil` on read failure or when the offset is past the
    /// end of the file (truncation/rewrite — the caller restarts from 0).
    func chunk(of ref: TranscriptRef, fromByteOffset: Int64) -> TranscriptChunk?
}

/// Filesystem discovery of Claude Code transcript files from two scan roots:
///
/// - **CLI** (`~/.claude/projects`): each immediate subdirectory is a project,
///   and `*.jsonl` files directly inside it are transcripts.
/// - **Desktop** (`~/Library/Application Support/Claude/local-agent-mode-sessions`):
///   transcripts are nested under a `…/.claude/projects/…` path.
///
/// In both cases, files under a `/subagents/` path component are ignored, and a
/// missing root simply contributes nothing (never crashes).
// FileManager is not `Sendable`, but we only use it for read-only enumeration and
// never mutate shared state, so opting out of the check is safe here.
public struct TranscriptSource: TranscriptDiscovering, @unchecked Sendable {
    private let cliRoot: URL
    private let desktopRoot: URL
    private let fileManager: FileManager

    public init(cliRoot: URL = TranscriptSource.defaultCLIRoot,
                desktopRoot: URL = TranscriptSource.defaultDesktopRoot,
                fileManager: FileManager = .default) {
        self.cliRoot = cliRoot
        self.desktopRoot = desktopRoot
        self.fileManager = fileManager
    }

    /// `~/.claude/projects`.
    public static var defaultCLIRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// `~/Library/Application Support/Claude/local-agent-mode-sessions`.
    public static var defaultDesktopRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
    }

    public func discover() -> [TranscriptRef] {
        discoverCLI() + discoverDesktop()
    }

    public func lines(of ref: TranscriptRef) -> [String] {
        guard let data = try? Data(contentsOf: ref.url) else { return [] }
        return Self.splitLines(data)
    }

    public func chunk(of ref: TranscriptRef, fromByteOffset offset: Int64) -> TranscriptChunk? {
        guard offset >= 0, let handle = try? FileHandle(forReadingFrom: ref.url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), offset <= size else { return nil }
        guard offset < size else { return TranscriptChunk(lines: [], endOffset: offset) }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.readToEnd()
        else { return nil }

        // Consume only up to the final newline; a partial trailing line (a write
        // in flight) stays unread until it is completed by a later append.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            return TranscriptChunk(lines: [], endOffset: offset)
        }
        let complete = data[data.startIndex...lastNewline]
        return TranscriptChunk(
            lines: Self.splitLines(Data(complete)),
            endOffset: offset + Int64(complete.count)
        )
    }

    /// Split JSONL bytes on `\n` (tolerating `\r\n`), decoding each line as UTF-8.
    /// Byte splitting avoids the CharacterSet scan and the 2-3x transient String
    /// peak of `components(separatedBy: .newlines)` on multi-MB transcripts.
    static func splitLines(_ data: Data) -> [String] {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { slice -> String in
                var slice = slice
                if slice.last == UInt8(ascii: "\r") { slice = slice.dropLast() }
                return String(decoding: slice, as: UTF8.self)
            }
        // Drop a single trailing empty line (the common case of a file ending
        // in a newline), but keep genuinely empty intermediate lines.
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    // MARK: - CLI

    /// For each immediate subdirectory of `cliRoot`, collect `*.jsonl` files
    /// directly inside it, plus subagent transcripts one level deeper at
    /// `<sessionDir>/subagents/*.jsonl` (attributed to that session).
    private func discoverCLI() -> [TranscriptRef] {
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: cliRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return projectDirs.flatMap { projectDir -> [TranscriptRef] in
            guard isDirectory(projectDir) else { return [] }
            guard let entries = try? fileManager.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            var refs: [TranscriptRef] = []
            for url in entries {
                if isTranscriptFile(url) {
                    refs.append(makeRef(url: url, origin: .cli))
                } else if isDirectory(url) {
                    refs.append(contentsOf: subagentRefs(inSessionDir: url, origin: .cli))
                }
            }
            return refs
        }
    }

    /// `<sessionDir>/subagents/*.jsonl`, attributed to the session dir's name.
    private func subagentRefs(inSessionDir sessionDir: URL, origin: SessionOrigin) -> [TranscriptRef] {
        let subagentsDir = sessionDir.appendingPathComponent("subagents", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: subagentsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return files.compactMap { url in
            guard isTranscriptFile(url) else { return nil }
            return makeRef(url: url, origin: origin, parentID: sessionDir.lastPathComponent)
        }
    }

    // MARK: - Desktop

    /// Recursively walk `desktopRoot` for `*.jsonl` files whose full path
    /// contains `/.claude/projects/` and does NOT contain `/subagents/`.
    private func discoverDesktop() -> [TranscriptRef] {
        // Do NOT skip hidden files here: the transcripts live under a `.claude`
        // directory, which is hidden, so skipping hidden entries would prevent
        // the enumerator from ever descending into it.
        guard let enumerator = fileManager.enumerator(
            at: desktopRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else {
            return []
        }

        var refs: [TranscriptRef] = []
        for case let url as URL in enumerator {
            guard isTranscriptFile(url) else { continue }
            guard url.path.contains("/.claude/projects/") else { continue }
            refs.append(makeRef(url: url, origin: .desktop, parentID: subagentParentID(of: url)))
        }
        return refs
    }

    /// For `…/<sessionId>/subagents/agent-x.jsonl`, the `<sessionId>` component;
    /// nil when the path has no `subagents` component.
    private func subagentParentID(of url: URL) -> String? {
        let components = url.pathComponents
        guard let index = components.lastIndex(of: "subagents"), index > 0 else { return nil }
        return components[index - 1]
    }

    // MARK: - Helpers

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isTranscriptFile(_ url: URL) -> Bool {
        url.pathExtension == "jsonl"
    }

    private func makeRef(url: URL, origin: SessionOrigin, parentID: String? = nil) -> TranscriptRef {
        let id = url.deletingPathExtension().lastPathComponent
        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date(timeIntervalSince1970: 0)
        return TranscriptRef(id: id, url: url, origin: origin, title: nil, modifiedAt: modifiedAt,
                             parentID: parentID)
    }
}
