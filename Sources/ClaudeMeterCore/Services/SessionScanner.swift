import Foundation

/// The product of one scan: every session (sorted by total tokens, descending)
/// plus the compact snapshot for the widget.
public struct ScanResult: Sendable, Equatable {
    public let sessions: [SessionUsage]
    public let snapshot: SessionSnapshot

    public init(sessions: [SessionUsage], snapshot: SessionSnapshot) {
        self.sessions = sessions
        self.snapshot = snapshot
    }
}

/// Orchestrates a full sessions scan: discover transcripts, fold each file's
/// newly appended lines into its cached accumulator (files whose modification
/// date is unchanged aren't even opened), resolve which are live, and rank them.
///
/// An `actor` because it owns the mutable per-file cache; all dependencies are
/// injected so it is fully testable with fakes.
public actor SessionScanner {
    private struct CacheEntry {
        let modifiedAt: Date
        /// Resume point: first byte after the last consumed newline.
        let byteOffset: Int64
        let accumulator: SessionAccumulator
    }

    private let discoverer: TranscriptDiscovering
    private let processProbe: ProcessProbing
    private let desktopDetector: DesktopAppDetecting
    private let parser: TranscriptParser
    private let resolver: RunningResolver
    private let snapshotLimit: Int
    private let burnWindow: TimeInterval
    private let canonicalize: @Sendable (String) -> String
    /// Keyed by file path (session ids could collide across scan roots).
    private var cache: [String: CacheEntry] = [:]

    public init(
        discoverer: TranscriptDiscovering,
        processProbe: ProcessProbing,
        desktopDetector: DesktopAppDetecting,
        parser: TranscriptParser = TranscriptParser(),
        resolver: RunningResolver = RunningResolver(),
        snapshotLimit: Int = 5,
        burnWindow: TimeInterval = 300,
        canonicalize: @escaping @Sendable (String) -> String = SessionScanner.realPath
    ) {
        self.discoverer = discoverer
        self.processProbe = processProbe
        self.desktopDetector = desktopDetector
        self.parser = parser
        self.resolver = resolver
        self.snapshotLimit = snapshotLimit
        self.burnWindow = burnWindow
        self.canonicalize = canonicalize
    }

    /// Kernel-truth canonicalization (matches libproc's resolved cwds, including
    /// the `/tmp` -> `/private/tmp` prefix that Foundation's symlink resolution
    /// deliberately strips). Unresolvable paths (deleted dirs) pass through.
    public static let realPath: @Sendable (String) -> String = { path in
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    public func scan(now: Date) -> ScanResult {
        let refs = discoverer.discover()
        var nextCache: [String: CacheEntry] = [:]
        var parents: [(ref: TranscriptRef, accumulator: SessionAccumulator)] = []
        var subagentsByParent: [String: SessionAccumulator] = [:]

        for ref in refs {
            let key = ref.url.path
            let entry: CacheEntry?
            if let cached = cache[key], cached.modifiedAt == ref.modifiedAt {
                entry = cached   // unchanged file: not even opened
            } else {
                entry = refreshedEntry(for: ref, cached: cache[key])
            }
            guard let entry else { continue }
            nextCache[key] = entry
            if let parentID = ref.parentID {
                let merged = subagentsByParent[parentID].map { $0.merged(with: entry.accumulator) }
                subagentsByParent[parentID] = merged ?? entry.accumulator
            } else {
                parents.append((ref, entry.accumulator))
            }
        }
        cache = nextCache

        // Session activity signal for liveness = the transcript file's mtime
        // (moves on user messages too, unlike the last assistant record), taking
        // the newest of the parent file and its subagent files.
        var activityAt: [String: Date] = [:]
        for ref in refs {
            let sessionID = ref.parentID ?? ref.id
            activityAt[sessionID] = max(activityAt[sessionID] ?? .distantPast, ref.modifiedAt)
        }

        // Usage is re-snapshot each scan so the burn rate decays with `now` even
        // for files that haven't changed. Subagent usage folds into its parent
        // session (the parent transcript's cwd wins for process matching).
        // projectPath "" => derive the real cwd from the records, then
        // canonicalize it to kernel truth so it matches the probe's cwds.
        var usages: [SessionUsage] = []
        for (ref, accumulator) in parents {
            let merged = subagentsByParent[ref.id].map { accumulator.merged(with: $0) } ?? accumulator
            if let usage = merged.usage(
                id: ref.id, projectPath: "", origin: ref.origin, title: ref.title, now: now
            ) {
                usages.append(usage.withProjectPath(canonicalize(usage.projectPath)))
            }
        }

        let liveCounts = processProbe.liveClaudeCwdCounts()
        let desktopRunning = desktopDetector.isClaudeDesktopRunning()
        let resolved = resolver.resolve(
            sessions: usages, liveCwdCounts: liveCounts, desktopAppRunning: desktopRunning,
            activityAt: activityAt, now: now
        )
        let sorted = resolved.sorted { $0.totalTokens > $1.totalTokens }
        // The published snapshot feeds the widget, which shows only active sessions.
        let snapshot = SessionSnapshot.make(from: resolved, now: now, limit: snapshotLimit, runningOnly: true)
        return ScanResult(sessions: sorted, snapshot: snapshot)
    }

    /// Fold a changed file's new lines into its accumulator, resuming from the
    /// cached byte offset. A failed resume (offset past EOF — the file was
    /// truncated or rewritten) restarts from byte 0 with a fresh accumulator.
    private func refreshedEntry(for ref: TranscriptRef, cached: CacheEntry?) -> CacheEntry? {
        var accumulator = cached?.accumulator ?? SessionAccumulator(burnWindow: burnWindow)
        let resumeOffset = cached?.byteOffset ?? 0
        var chunk = discoverer.chunk(of: ref, fromByteOffset: resumeOffset)
        if chunk == nil, resumeOffset > 0 {
            accumulator = SessionAccumulator(burnWindow: burnWindow)
            chunk = discoverer.chunk(of: ref, fromByteOffset: 0)
        }
        guard let chunk else { return nil }   // unreadable this scan; retry next scan
        for record in parser.parse(chunk.lines).records {
            accumulator.fold(record)
        }
        return CacheEntry(modifiedAt: ref.modifiedAt, byteOffset: chunk.endOffset, accumulator: accumulator)
    }
}
