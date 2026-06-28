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

/// Orchestrates a full sessions scan: discover transcripts, parse + aggregate
/// each (skipping files whose modification date is unchanged since the last
/// scan), resolve which are live, and rank them.
///
/// An `actor` because it owns a mutable parse cache; all dependencies are
/// injected so it is fully testable with fakes.
public actor SessionScanner {
    private struct CacheEntry {
        let modifiedAt: Date
        let usage: SessionUsage
    }

    private let discoverer: TranscriptDiscovering
    private let processProbe: ProcessProbing
    private let desktopDetector: DesktopAppDetecting
    private let parser: TranscriptParser
    private let aggregator: SessionAggregator
    private let resolver: RunningResolver
    private let snapshotLimit: Int
    private var cache: [String: CacheEntry] = [:]

    public init(
        discoverer: TranscriptDiscovering,
        processProbe: ProcessProbing,
        desktopDetector: DesktopAppDetecting,
        parser: TranscriptParser = TranscriptParser(),
        aggregator: SessionAggregator = SessionAggregator(),
        resolver: RunningResolver = RunningResolver(),
        snapshotLimit: Int = 5
    ) {
        self.discoverer = discoverer
        self.processProbe = processProbe
        self.desktopDetector = desktopDetector
        self.parser = parser
        self.aggregator = aggregator
        self.resolver = resolver
        self.snapshotLimit = snapshotLimit
    }

    public func scan(now: Date) -> ScanResult {
        let refs = discoverer.discover()
        var nextCache: [String: CacheEntry] = [:]
        var usages: [SessionUsage] = []

        for ref in refs {
            // Reuse a cached aggregate when the file hasn't changed.
            if let cached = cache[ref.id], cached.modifiedAt == ref.modifiedAt {
                nextCache[ref.id] = cached
                usages.append(cached.usage)
                continue
            }
            let parsed = parser.parse(discoverer.lines(of: ref))
            // projectPath "" => aggregator derives the real cwd from the records,
            // which is what the process probe matches against.
            guard let usage = aggregator.aggregate(
                parsed, id: ref.id, projectPath: "", origin: ref.origin, title: ref.title, now: now
            ) else { continue }
            nextCache[ref.id] = CacheEntry(modifiedAt: ref.modifiedAt, usage: usage)
            usages.append(usage)
        }
        cache = nextCache

        let liveCounts = processProbe.liveClaudeCwdCounts()
        let desktopRunning = desktopDetector.isClaudeDesktopRunning()
        let resolved = resolver.resolve(
            sessions: usages, liveCwdCounts: liveCounts, desktopAppRunning: desktopRunning, now: now
        )
        let sorted = resolved.sorted { $0.totalTokens > $1.totalTokens }
        let snapshot = SessionSnapshot.make(from: resolved, now: now, limit: snapshotLimit)
        return ScanResult(sessions: sorted, snapshot: snapshot)
    }
}
