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

    public init(id: String, url: URL, origin: SessionOrigin, title: String?, modifiedAt: Date) {
        self.id = id
        self.url = url
        self.origin = origin
        self.title = title
        self.modifiedAt = modifiedAt
    }
}

/// Discovers transcript files and reads their raw lines.
public protocol TranscriptDiscovering: Sendable {
    /// All discovered transcripts: CLI refs first, then desktop refs.
    func discover() -> [TranscriptRef]
    /// Raw lines of a transcript; `[]` on any read failure.
    func lines(of ref: TranscriptRef) -> [String]
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
        guard let text = try? String(contentsOf: ref.url, encoding: .utf8) else {
            return []
        }
        var lines = text.components(separatedBy: .newlines)
        // Drop a single trailing empty line (the common case of a file ending
        // in a newline), but keep genuinely empty intermediate lines.
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    // MARK: - CLI

    /// For each immediate subdirectory of `cliRoot`, collect `*.jsonl` files
    /// directly inside it, skipping anything under a `/subagents/` component.
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
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            return entries.compactMap { url in
                guard isTranscriptFile(url), !containsSubagents(url) else { return nil }
                return makeRef(url: url, origin: .cli)
            }
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
            let path = url.path
            guard path.contains("/.claude/projects/"), !path.contains("/subagents/") else {
                continue
            }
            refs.append(makeRef(url: url, origin: .desktop))
        }
        return refs
    }

    // MARK: - Helpers

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isTranscriptFile(_ url: URL) -> Bool {
        url.pathExtension == "jsonl"
    }

    private func containsSubagents(_ url: URL) -> Bool {
        url.pathComponents.contains("subagents")
    }

    private func makeRef(url: URL, origin: SessionOrigin) -> TranscriptRef {
        let id = url.deletingPathExtension().lastPathComponent
        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date(timeIntervalSince1970: 0)
        return TranscriptRef(id: id, url: url, origin: origin, title: nil, modifiedAt: modifiedAt)
    }
}
