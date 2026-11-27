import Foundation

/// The product of one Codex scan: Codex sessions (sorted by total tokens,
/// descending), the live Codex processes, which sessions may be armed, the
/// account's newest limit reading and whether Codex is "present" at all.
public struct CodexScanResult: Sendable, Equatable {
    public let sessions: [SessionUsage]
    public let processes: [LiveProcess]
    public let armableSessionIDs: [String]
    /// `CodexLimits.newest` over every per-id reading of every non-import session.
    public let limits: CodexLimitReading?
    /// At least one non-import session has used tokens or carries a limit reading.
    /// Gates every Codex surface in the UI.
    public let isPresent: Bool

    public init(sessions: [SessionUsage], processes: [LiveProcess], armableSessionIDs: [String],
                limits: CodexLimitReading?, isPresent: Bool) {
        self.sessions = sessions
        self.processes = processes
        self.armableSessionIDs = armableSessionIDs
        self.limits = limits
        self.isPresent = isPresent
    }
}

/// Codex counterpart of `SessionScanner`: discovers `rollout-*.jsonl` transcripts,
/// folds each file's newly appended lines into its cached `CodexSessionState`
/// (unchanged files aren't opened), resolves liveness from Codex CLI processes and
/// computes the armable set.
///
/// Imported Claude threads are re-evaluated **every scan** against the current
/// imports file, not the flag cached at fold time: the imports file can appear
/// after a transcript was first folded.
public actor CodexScanner {
    private struct CacheEntry {
        let modifiedAt: Date
        /// Resume point: first byte after the last consumed newline.
        let byteOffset: Int64
        let state: CodexSessionState
    }

    /// The only originator a terminal session writes; nothing else is ever armable.
    static let terminalOriginator = "codex-tui"

    private let source: CodexTranscriptDiscovering
    private let processProbe: ProcessProbing
    private let resolver: RunningResolver
    private let canonicalize: @Sendable (String) -> String
    private let executablePathForPID: @Sendable (Int32) -> String?
    private let parentPIDForPID: @Sendable (Int32) -> Int32
    private let terminalDetector = TerminalDetector()
    /// Keyed by file path.
    private var cache: [String: CacheEntry] = [:]

    public init(
        source: CodexTranscriptDiscovering,
        processProbe: ProcessProbing,
        resolver: RunningResolver = RunningResolver(),
        canonicalize: @escaping @Sendable (String) -> String = SessionScanner.realPath,
        executablePathForPID: @escaping @Sendable (Int32) -> String? = { LibprocProcessProbe.executablePathForPID($0) },
        parentPIDForPID: @escaping @Sendable (Int32) -> Int32 = { LibprocProcessProbe.parentPIDForPID($0) },
    ) {
        self.source = source
        self.processProbe = processProbe
        self.resolver = resolver
        self.canonicalize = canonicalize
        self.executablePathForPID = executablePathForPID
        self.parentPIDForPID = parentPIDForPID
    }

    public func scan(now: Date) -> CodexScanResult {
        let refs = source.discover()
        let importedIDs = source.importedIDs()
        var nextCache: [String: CacheEntry] = [:]
        var included: [(ref: TranscriptRef, state: CodexSessionState)] = []

        for ref in refs {
            let key = ref.url.path
            let entry: CacheEntry? = if let cached = cache[key], cached.modifiedAt == ref.modifiedAt {
                cached // unchanged file: not even opened
            } else {
                refreshedEntry(for: ref, cached: cache[key], importedIDs: importedIDs)
            }
            guard let entry else { continue }
            nextCache[key] = entry
            if !Self.isImport(entry.state, refID: ref.id, importedIDs: importedIDs) {
                included.append((ref, entry.state))
            }
        }
        cache = nextCache

        let usages = included.map { usage(ref: $0.ref, state: $0.state) }
        let processes = processProbe.liveCodexProcesses()
        let resolved = resolver.resolve(
            sessions: usages,
            liveCwdCounts: LibprocProcessProbe.tally(processes: processes),
            desktopAppRunning: false,
            activityAt: Dictionary(included.map { ($0.ref.id, $0.ref.modifiedAt) }, uniquingKeysWith: max),
            now: now,
        )
        let terminalIDs = Set(included.filter { $0.state.originator == Self.terminalOriginator }.map(\.ref.id))
        return CodexScanResult(
            sessions: resolved.sorted { $0.totalTokens > $1.totalTokens },
            processes: processes,
            armableSessionIDs: armableIDs(sessions: resolved, terminalIDs: terminalIDs, processes: processes),
            limits: CodexLimits.newest(included.flatMap { Array($0.state.latestLimitsByID.values) }),
            isPresent: included.contains { $0.state.tokens.total > 0 || !$0.state.latestLimitsByID.isEmpty },
        )
    }

    /// An imported Claude thread that has not accrued Codex tokens. Checked against
    /// this scan's imports file as well as the flag set when its lines were folded.
    static func isImport(_ state: CodexSessionState, refID: String, importedIDs: Set<String>) -> Bool {
        guard state.isLegacyHistory, state.tokens.total == 0 else { return false }
        return state.isImportedLegacy || importedIDs.contains(state.id ?? refID)
    }

    private func usage(ref: TranscriptRef, state: CodexSessionState) -> SessionUsage {
        SessionUsage(
            id: ref.id,
            origin: ref.origin,
            projectPath: state.cwd.map(canonicalize) ?? "",
            title: ref.title,
            models: state.models,
            lastModel: state.model,
            tokens: state.tokens,
            messageCount: state.turnCount,
            firstActivity: state.firstActivity ?? ref.modifiedAt,
            lastActivity: state.lastActivity ?? ref.modifiedAt,
            // Codex reports cumulative totals, not per-turn usage: no burn window.
            burnRate: 0,
            tool: .codex,
        )
    }

    /// Armable: a `codex-tui` terminal session, running, mapped to exactly one live
    /// Codex process by cwd, whose owning terminal is drivable (iTerm2).
    private func armableIDs(sessions: [SessionUsage], terminalIDs: Set<String>,
                            processes: [LiveProcess]) -> [String] {
        let byCwd = Dictionary(grouping: processes, by: \.cwd)
        return sessions.compactMap { session in
            guard session.origin == .codexCLI, terminalIDs.contains(session.id),
                  session.running == .running,
                  let matches = byCwd[session.projectPath], matches.count == 1
            else { return nil }
            let kind = terminalDetector.detect(startPID: matches[0].pid,
                                               executablePathForPID: executablePathForPID,
                                               parentPIDForPID: parentPIDForPID)
            return kind.isDrivable ? session.id : nil
        }
    }

    /// Fold a changed file's new lines onto its cached state, resuming from the
    /// cached byte offset. A failed resume (offset past EOF: truncated or rewritten)
    /// restarts from byte 0 with a fresh state; an unreadable file keeps its cached
    /// entry so the session stays visible and the next scan resumes from there.
    private func refreshedEntry(for ref: TranscriptRef, cached: CacheEntry?,
                                importedIDs: Set<String>) -> CacheEntry? {
        var state = cached?.state ?? CodexSessionState()
        let resumeOffset = cached?.byteOffset ?? 0
        var chunk = source.chunk(of: ref, fromByteOffset: resumeOffset)
        if chunk == nil, resumeOffset > 0 {
            state = CodexSessionState()
            chunk = source.chunk(of: ref, fromByteOffset: 0)
        }
        guard let chunk else { return cached }
        return CacheEntry(modifiedAt: ref.modifiedAt, byteOffset: chunk.endOffset,
                          state: state.folding(chunk.lines, importedIDs: importedIDs))
    }
}
