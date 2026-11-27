import ClaudeMeterCore
import Foundation
import SwiftUI
import WidgetKit

/// Inputs the AppDelegate forwards to the AutoResumeCoordinator after each scan.
struct UsageContextInputs {
    /// Claude and Codex sessions together (IDs are unique across tools).
    let sessions: [SessionUsage]
    /// Live Claude Code CLI processes.
    let processes: [LiveProcess]
    /// Live terminal Codex CLI processes.
    let codexProcesses: [LiveProcess]
    /// Claude and Codex armable IDs together.
    let armableIDs: [String]
    /// The Codex limit reading as of this scan (past-reset windows read as full), or nil.
    let codexLimits: UsageSnapshot?
    /// The Codex window `rate_limit_reached_type` says cut sessions off, until it resets.
    let codexReached: LimitWindow?
    /// When this scan ran — the instant `codexLimits` was evaluated at.
    let scannedAt: Date
}

/// Observable view-model that periodically scans local Claude Code transcripts
/// and publishes per-session token usage with live-status, for the Sessions
/// window (and, later, the widget snapshot).
///
/// The heavy file/process work happens inside the `SessionScanner` actor, off
/// the main thread; only the published results land here on the main actor.
@MainActor
final class SessionMonitor: ObservableObject {
    @Published private(set) var sessions: [SessionUsage] = []
    @Published private(set) var snapshot: SessionSnapshot?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var latestProcesses: [LiveProcess] = []
    @Published private(set) var latestCodexProcesses: [LiveProcess] = []
    /// Codex's limit windows as of the last scan (a window whose reset passed reads as
    /// full), or nil with no reading. Never merged with Claude's: both have a "Weekly".
    @Published private(set) var codexLimits: UsageSnapshot?
    /// When the Codex limit reading was observed (the last Codex turn that carried one,
    /// or the last live ChatGPT fetch).
    @Published private(set) var codexAsOf: Date?
    /// The Codex reading shown — the newer of live and transcript (`CodexLimitSource`).
    @Published private(set) var codexReading: CodexLimitReading?
    /// The live ChatGPT reading as of the last scan (nil when signed out).
    @Published private(set) var codexLiveReading: CodexLimitReading?
    /// Codex is in use on this Mac (≥ 1 non-import session with tokens or a limit
    /// reading), or a live ChatGPT reading exists. Every Codex surface is gated on it.
    @Published private(set) var codexPresent = false
    /// Codex's burn rate, pace and sparkline, from `codex-history.json` (one sample per
    /// Codex reading, never per scan — see `CodexHistory`).
    @Published private(set) var codexInsights: UsageInsights = .empty

    /// Set by AppDelegate so the published snapshot can mark armed sessions and
    /// the post-scan hook can drive auto-resume.
    var armedIDsProvider: (() -> [String])?
    var onScan: ((UsageContextInputs) -> Void)?
    /// Set by AppDelegate so the widget snapshot can carry account usage gauges.
    var usageProvider: (() -> UsageSnapshot?)?
    /// Which tools the widget may show: `limitTools` get gauges (connected and shown),
    /// `hidden` lose their gauges and session rows. Read after `codexPresent` is set.
    var widgetToolsProvider: (() -> (limitTools: [AgentTool], hidden: [AgentTool]))?
    /// The time-format setting, stamped into each snapshot for the widget.
    var clockStyleProvider: (() -> ClockStyle)?
    /// Called after every scan that has a Codex limit reading, with that snapshot and
    /// the scan time — the hook for Codex limit alerts.
    var onCodexLimits: ((UsageSnapshot, Date) -> Void)?
    /// The live ChatGPT Codex reading, when signed in. Merged with the transcript reading
    /// by `CodexLimitSource.pick`, so everything downstream sees one reading.
    var liveCodexProvider: (() -> CodexLimitReading?)?

    private let scanner: SessionScanner
    private let codexScanner: CodexScanner
    private let interval: TimeInterval
    private let snapshotStore = SnapshotStore()
    private var timer: Timer?
    private var isScanning = false
    private var codexHistory: [UsageSample] = CodexUsageHistory.load()
    /// When `codexInsights` was last computed, so an unchanged history is re-derived
    /// (for the burn's decay to idle) at most once a minute, not every scan.
    private var codexInsightsAt: Date?
    private static let codexInsightsInterval: TimeInterval = 60
    /// Whether this run has seeded `codexHistory` from the transcripts (once, after
    /// the first scan).
    private var codexBackfillDone = false

    /// Bundle id of the widget extension.
    nonisolated static let widgetBundleID = "com.jakubzak.claudemeter.ClaudeMeterWidget"

    /// The widget's own sandbox container Documents path. A non-sandboxed app can
    /// write here, and the sandboxed widget can always read its own container —
    /// unlike the App Group container, which the widget is denied reading from when
    /// the writer is a non-sandboxed process.
    nonisolated static func widgetInboxURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(widgetBundleID)/Data/Documents", isDirectory: true)
            .appendingPathComponent("snapshot.json")
    }

    /// Local copy under Application Support — always writable, useful for diagnostics.
    nonisolated static func localSnapshotURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeMeter", isDirectory: true)
            .appendingPathComponent("snapshot.json")
    }

    /// Publish the snapshot to the widget's container and to the local Application
    /// Support copy on every scan (two small files; the widget reads `generatedAt`
    /// to tell a live app from a dead one, so the file must keep moving), but
    /// reload widget timelines only when something the widget can't wait for
    /// changed (which sessions run, what's armed, the gauges) or, for token-count
    /// changes, at most every 5 minutes. WidgetKit budgets ~40–70 reloads a day
    /// for a background app, and a streaming session moves the count on every
    /// 10 s scan (measured: ~2,400 reloads/day).
    private var lastStructure: [String]?
    private var lastTokens: [String]?
    private var lastReloadAt: Date?
    func publish(_ snapshot: SessionSnapshot, now: Date = Date()) {
        // Deliver into the widget's own container (the only place the sandboxed
        // widget can reliably read from a non-sandboxed writer). Local copy for
        // diagnostics.
        try? snapshotStore.write(snapshot, to: Self.widgetInboxURL())
        try? snapshotStore.write(snapshot, to: Self.localSnapshotURL())

        let structure = snapshot.sessions
            .map { "\($0.id):\($0.running.rawValue):\($0.lastModel ?? "")" }
            + ["running:\(snapshot.runningCount)",
               "armed:\(snapshot.armedSessionIDs.sorted().joined(separator: ","))",
               "armable:\(snapshot.armableSessionIDs.sorted().joined(separator: ","))"]
            + snapshot.usageGauges
            .map { "\($0.label):\(Int($0.percentLeft)):\($0.resetsAt?.timeIntervalSince1970 ?? 0)" }
            + [Self.extraUsageStructureKey(snapshot.extraUsage),
               "clock:\(snapshot.clockStyle?.rawValue ?? "")"]
            + (snapshot.codexGauges ?? [])
            .map { "codex:\($0.label):\(Int($0.percentLeft)):\($0.resetsAt?.timeIntervalSince1970 ?? 0)" }
        // Display-rounded, so a count that renders the same doesn't count as a change.
        // The extra-usage amount belongs here rather than in `structure` for the same
        // reason: spend moves on almost every scan while a session streams, and an
        // immediate reload per cent is the ~2,400/day regression this split prevents.
        let tokens = snapshot.sessions.map { "\($0.id):\(Formatting.tokenCount($0.totalTokens))" }
            + ["total:\(Formatting.tokenCount(snapshot.totalTokens))",
               "extra:\(snapshot.extraUsage.map(\.headline) ?? "")"]
        let structureChanged = structure != lastStructure
        let tokensChanged = tokens != lastTokens
        lastStructure = structure
        lastTokens = tokens
        guard structureChanged || tokensChanged else { return }

        let sinceReload = lastReloadAt.map { now.timeIntervalSince($0) } ?? .infinity
        guard structureChanged || sinceReload >= Self.minReloadInterval else { return }
        lastReloadAt = now
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The parts of extra usage the widget must not wait five minutes for: whether the
    /// row appears at all, whether spending is blocked, and which colour band it is in.
    /// The amount itself is deliberately excluded — it changes far too often to drive an
    /// immediate reload.
    private static func extraUsageStructureKey(_ usage: ExtraUsage?) -> String {
        guard let usage else { return "extra:none" }
        let band = usage.percentUsed.map { percent -> String in
            switch percent {
            case 95...: "critical"
            case 80...: "warn"
            default: "normal"
            }
        } ?? "uncapped"
        return "extra:\(usage.isEnabled):\(usage.used.isZero):\(usage.isBlocked):\(band)"
    }

    /// Token-only changes reload at most this often (matches the widget's timeline).
    private static let minReloadInterval: TimeInterval = 5 * 60

    init(scanner: SessionScanner = SessionMonitor.makeDefaultScanner(),
         codexScanner: CodexScanner = SessionMonitor.makeDefaultCodexScanner(),
         interval: TimeInterval = 10) {
        self.scanner = scanner
        self.codexScanner = codexScanner
        self.interval = interval
    }

    /// The production Codex scanner: `~/.codex/sessions` and the live Codex CLI processes.
    nonisolated static func makeDefaultCodexScanner() -> CodexScanner {
        CodexScanner(source: CodexTranscriptSource(), processProbe: LibprocProcessProbe())
    }

    /// The production scanner wired to the real filesystem and process table.
    nonisolated static func makeDefaultScanner() -> SessionScanner {
        SessionScanner(
            discoverer: TranscriptSource(),
            processProbe: LibprocProcessProbe(),
            desktopDetector: DesktopAppProbe(),
            snapshotLimit: 20, // enough running sessions to fill the extra-large widget
        )
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer.tolerance = interval / 10
        self.timer = timer
        Task { await refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Run one scan now and publish the results. Skips if a scan is in flight.
    /// Processes and the armable set come out of the scan itself (probed once,
    /// off the main actor).
    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let now = Date()
        async let claudeScan = scanner.scan(now: now)
        async let codexScan = codexScanner.scan(now: now)
        let result = await claudeScan
        let codex = await codexScan
        let processes = result.processes
        let armedIDs = armedIDsProvider?() ?? []

        // No Codex surface at all until Codex is present (a fresh zero-token thread
        // or an imported Claude thread alone must not change anything).
        let codexSessions = codex.isPresent ? codex.sessions : []
        let allSessions = (result.sessions + codexSessions).sorted { $0.totalTokens > $1.totalTokens }
        sessions = allSessions
        latestProcesses = processes
        latestCodexProcesses = codex.processes
        // The newer of the live ChatGPT reading and the transcript one, so the gauges,
        // pill, history, alerts and the auto-resume gate all see the freshest figure.
        let live = liveCodexProvider?()
        let reading = CodexLimitSource.pick(live: live, transcript: codex.limits)
        let present = codex.isPresent || live != nil
        // Rebuilt from the reading every scan: a window whose reset passed since must
        // read as full now, not when the next Codex turn happens to arrive.
        let codexUsage = reading.map { CodexLimits.snapshot(from: $0, now: now) }
        codexLimits = codexUsage
        codexAsOf = reading?.observedAt
        codexReading = reading
        codexLiveReading = live
        codexPresent = present
        await backfillCodexHistoryOnce(reading: reading, now: now)
        recordCodexHistory(reading, now: now)
        let armedSet = Set(armedIDs)
        let armable = result.armableSessionIDs + (codex.isPresent ? codex.armableSessionIDs : [])
        let widgetSessions = allSessions.filter { $0.running == .running || armedSet.contains($0.id) }
        let snap = SessionSnapshot.make(
            from: widgetSessions, now: result.snapshot.generatedAt,
            limit: 20, runningOnly: false, armedSessionIDs: armedIDs, armableSessionIDs: armable,
        )
        // Preserve the true running count across ALL sessions, not just the filtered set.
        let trueRunning = allSessions.filter { $0.running == .running }.count
        let usage = usageProvider?()
        let widgetTools = widgetToolsProvider?() ?? (limitTools: [.claude], hidden: [])
        // Gauges only for connected, shown tools: transcript-only Codex limits stay off
        // the widget's rings (its sessions still show).
        let showCodex = present && widgetTools.limitTools.contains(.codex) ? codexUsage : nil
        let claudeGauges = widgetTools.limitTools.contains(.claude) ? usage?.gauges ?? [] : []
        snapshot = SessionSnapshot(
            generatedAt: snap.generatedAt, sessions: snap.sessions,
            totalTokens: allSessions.reduce(0) { $0 + $1.totalTokens },
            runningCount: trueRunning, armedSessionIDs: armedIDs, armableSessionIDs: armable,
            usageGauges: claudeGauges, extraUsage: widgetTools.hidden.contains(.claude) ? nil : usage?.extraUsage,
            clockStyle: clockStyleProvider?(),
            codexGauges: showCodex?.gauges, codexAsOf: showCodex == nil ? nil : reading?.observedAt,
            hiddenTools: widgetTools.hidden.isEmpty ? nil : widgetTools.hidden,
        )
        lastUpdated = snapshot!.generatedAt
        publish(snapshot!)

        if let codexUsage { onCodexLimits?(codexUsage, now) }
        onScan?(UsageContextInputs(sessions: allSessions, processes: processes,
                                   codexProcesses: codex.processes, armableIDs: armable,
                                   codexLimits: codexUsage,
                                   codexReached: CodexLimits.reachedWindow(reading, now: now),
                                   scannedAt: now))
    }

    /// Seed Codex's history from the readings already in its transcripts when it lacks
    /// the current window's start (a fresh install, or history recorded only since the
    /// last update), so the graph and pace don't start from nothing.
    private func backfillCodexHistoryOnce(reading: CodexLimitReading?, now: Date) async {
        guard !codexBackfillDone else { return }
        codexBackfillDone = true
        guard CodexHistory.needsBackfill(history: codexHistory, reading: reading) else { return }
        let readings = await codexScanner.limitReadingHistory()
        let merged = CodexHistory.backfilled(readings: readings, now: now, history: codexHistory)
        guard merged != codexHistory else { return }
        codexHistory = CodexUsageHistory.replace(with: merged)
        codexInsightsAt = nil
    }

    /// Append the reading to Codex's history (once per reading, plus one reset point)
    /// and refresh the insights: at once when samples were added, else at most once a
    /// minute — the burn depends on `now` (it decays to idle), so it can't wait forever.
    private func recordCodexHistory(_ reading: CodexLimitReading?, now: Date) {
        let samples = CodexHistory.samplesToRecord(reading: reading, now: now, history: codexHistory)
        codexHistory = CodexUsageHistory.append(samples, to: codexHistory)
        let due = codexInsightsAt.map { now.timeIntervalSince($0) >= Self.codexInsightsInterval } ?? true
        guard !samples.isEmpty || due else { return }
        codexInsightsAt = now
        let insights = UsageInsights.compute(history: codexHistory, now: now)
        if insights != codexInsights { codexInsights = insights }
    }

    /// Last `maxLines` non-empty lines of a session's transcript, for the cutoff gate.
    /// Reads only the file's tail: this runs on the main actor every scan while a
    /// resume window is open, and transcripts reach hundreds of MB.
    /// Codex transcripts are `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<id>.jsonl`.
    nonisolated static func tailLines(forSessionID id: String, tool: AgentTool = .claude,
                                      maxLines: Int = 40) -> [String] {
        let roots = switch tool {
        case .claude: [TranscriptSource.defaultCLIRoot, TranscriptSource.defaultDesktopRoot]
        case .codex: [CodexTranscriptSource.defaultHome.appendingPathComponent("sessions", isDirectory: true)]
        }
        let matches: (String) -> Bool = switch tool {
        case .claude: { $0 == "\(id).jsonl" }
        case .codex: { $0.hasPrefix("rollout-") && $0.hasSuffix("-\(id).jsonl") }
        }
        for root in roots {
            if let url = findTranscript(under: root, matching: matches) {
                guard let tail = tailBytes(of: url, count: tailReadBytes) else { return [] }
                let content = String(decoding: tail.data, as: UTF8.self)
                var lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                // The first line of a mid-file read is almost certainly cut in half.
                if tail.truncated, lines.count > 1 { lines.removeFirst() }
                return Array(lines.suffix(maxLines))
            }
        }
        return []
    }

    private nonisolated static let tailReadBytes = 256 * 1024

    /// The last `count` bytes; `truncated` when the file was longer than that (so the
    /// first line of `data` may start mid-line).
    private nonisolated static func tailBytes(of url: URL, count: Int) -> (data: Data, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let truncated = end > UInt64(count)
        let start = truncated ? end - UInt64(count) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return (data, truncated)
    }

    private nonisolated static func findTranscript(under root: URL, matching matches: (String) -> Bool) -> URL? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in e where matches(url.lastPathComponent) { return url }
        return nil
    }
}
