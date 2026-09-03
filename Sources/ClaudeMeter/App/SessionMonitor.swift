import ClaudeMeterCore
import Foundation
import SwiftUI
import WidgetKit

/// Inputs the AppDelegate forwards to the AutoResumeCoordinator after each scan.
struct UsageContextInputs {
    let sessions: [SessionUsage]
    let processes: [LiveProcess]
    let armableIDs: [String]
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

    /// Set by AppDelegate so the published snapshot can mark armed sessions and
    /// the post-scan hook can drive auto-resume.
    var armedIDsProvider: (() -> [String])?
    var onScan: ((UsageContextInputs) -> Void)?
    /// Set by AppDelegate so the widget snapshot can carry account usage gauges.
    var usageProvider: (() -> UsageSnapshot?)?

    private let scanner: SessionScanner
    private let interval: TimeInterval
    private let snapshotStore = SnapshotStore()
    private var timer: Timer?
    private var isScanning = false

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
    /// Support copy whenever anything changed; reload widget timelines only when
    /// something the widget can't wait for changed (which sessions run, what's armed,
    /// the gauges). Token counts alone ride the widget's own 5-minute timeline —
    /// WidgetKit budgets ~40–70 reloads a day for a background app, and a streaming
    /// session moves the count on every 10 s scan (measured: ~2,400 reloads/day).
    private var lastSignature: [String]?
    private var lastStructure: [String]?
    private var lastReloadAt: Date?
    func publish(_ snapshot: SessionSnapshot, now: Date = Date()) {
        let structure = snapshot.sessions
            .map { "\($0.id):\($0.running.rawValue):\($0.lastModel ?? "")" }
            + ["running:\(snapshot.runningCount)",
               "armed:\(snapshot.armedSessionIDs.sorted().joined(separator: ","))",
               "armable:\(snapshot.armableSessionIDs.sorted().joined(separator: ","))"]
            + snapshot.usageGauges
            .map { "\($0.label):\(Int($0.percentLeft)):\($0.resetsAt?.timeIntervalSince1970 ?? 0)" }
        let signature = structure
            + snapshot.sessions.map { "\($0.id):\(Formatting.tokenCount($0.totalTokens))" }
            + ["total:\(Formatting.tokenCount(snapshot.totalTokens))"]
        guard signature != lastSignature else { return }
        let structureChanged = structure != lastStructure
        lastSignature = signature
        lastStructure = structure

        // Deliver into the widget's own container (the only place the sandboxed
        // widget can reliably read from a non-sandboxed writer). Local copy for
        // diagnostics.
        try? snapshotStore.write(snapshot, to: Self.widgetInboxURL())
        try? snapshotStore.write(snapshot, to: Self.localSnapshotURL())

        let sinceReload = lastReloadAt.map { now.timeIntervalSince($0) } ?? .infinity
        guard structureChanged || sinceReload >= Self.minReloadInterval else { return }
        lastReloadAt = now
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Token-only changes reload at most this often (matches the widget's timeline).
    private static let minReloadInterval: TimeInterval = 5 * 60

    init(scanner: SessionScanner = SessionMonitor.makeDefaultScanner(),
         interval: TimeInterval = 10) {
        self.scanner = scanner
        self.interval = interval
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

        let result = await scanner.scan(now: Date())
        let processes = result.processes
        let armedIDs = armedIDsProvider?() ?? []

        sessions = result.sessions
        latestProcesses = processes
        let armedSet = Set(armedIDs)
        let armable = result.armableSessionIDs
        let widgetSessions = result.sessions.filter { $0.running == .running || armedSet.contains($0.id) }
        let snap = SessionSnapshot.make(
            from: widgetSessions, now: result.snapshot.generatedAt,
            limit: 20, runningOnly: false, armedSessionIDs: armedIDs, armableSessionIDs: armable,
        )
        // Preserve the true running count across ALL sessions, not just the filtered set.
        let trueRunning = result.sessions.filter { $0.running == .running }.count
        let gauges = usageProvider?()?.gauges ?? []
        snapshot = SessionSnapshot(
            generatedAt: snap.generatedAt, sessions: snap.sessions,
            totalTokens: result.sessions.reduce(0) { $0 + $1.totalTokens },
            runningCount: trueRunning, armedSessionIDs: armedIDs, armableSessionIDs: armable,
            usageGauges: gauges,
        )
        lastUpdated = snapshot!.generatedAt
        publish(snapshot!)

        onScan?(UsageContextInputs(sessions: result.sessions, processes: processes,
                                   armableIDs: armable))
    }

    /// Last `maxLines` non-empty lines of a session's transcript, for the cutoff gate.
    /// Reads only the file's tail: this runs on the main actor every scan while a
    /// resume window is open, and transcripts reach hundreds of MB.
    nonisolated static func tailLines(forSessionID id: String, maxLines: Int = 40) -> [String] {
        let roots = [TranscriptSource.defaultCLIRoot, TranscriptSource.defaultDesktopRoot]
        for root in roots {
            if let url = findTranscript(id: id, under: root) {
                guard let data = tailBytes(of: url, count: tailReadBytes) else { return [] }
                let content = String(decoding: data, as: UTF8.self)
                var lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                // The first line of a mid-file read is almost certainly cut in half.
                if data.count == tailReadBytes, lines.count > 1 { lines.removeFirst() }
                return Array(lines.suffix(maxLines))
            }
        }
        return []
    }

    private nonisolated static let tailReadBytes = 256 * 1024

    private nonisolated static func tailBytes(of url: URL, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(count) ? end - UInt64(count) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.readToEnd()
    }

    private nonisolated static func findTranscript(id: String, under root: URL) -> URL? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in e where url.lastPathComponent == "\(id).jsonl" { return url }
        return nil
    }
}
