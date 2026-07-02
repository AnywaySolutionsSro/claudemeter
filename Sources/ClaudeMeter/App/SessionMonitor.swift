import Foundation
import SwiftUI
import WidgetKit
import ClaudeMeterCore

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

    /// Publish the snapshot to the App Group container (for the widget) and to the
    /// local Application Support copy, then reload widget timelines — but only when
    /// the content actually changed, to avoid spending WidgetKit's reload budget.
    private var lastSignature: [String]?
    func publish(_ snapshot: SessionSnapshot) {
        let signature = snapshot.sessions.map { "\($0.id):\($0.totalTokens):\($0.running.rawValue)" }
            + ["running:\(snapshot.runningCount)", "total:\(snapshot.totalTokens)",
               "armed:\(snapshot.armedSessionIDs.sorted().joined(separator: ","))",
               "armable:\(snapshot.armableSessionIDs.sorted().joined(separator: ","))"]
            + snapshot.usageGauges.map { "\($0.label):\(Int($0.percentLeft)):\($0.resetsAt?.timeIntervalSince1970 ?? 0)" }
        guard signature != lastSignature else { return }
        lastSignature = signature

        // Deliver into the widget's own container (the only place the sandboxed
        // widget can reliably read from a non-sandboxed writer). Local copy for
        // diagnostics.
        try? snapshotStore.write(snapshot, to: Self.widgetInboxURL())
        try? snapshotStore.write(snapshot, to: Self.localSnapshotURL())
        WidgetCenter.shared.reloadAllTimelines()
    }

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
            snapshotLimit: 20   // enough running sessions to fill the extra-large widget
        )
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
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
            limit: 20, runningOnly: false, armedSessionIDs: armedIDs, armableSessionIDs: armable)
        // Preserve the true running count across ALL sessions, not just the filtered set.
        let trueRunning = result.sessions.filter { $0.running == .running }.count
        let gauges = usageProvider?()?.gauges ?? []
        snapshot = SessionSnapshot(
            generatedAt: snap.generatedAt, sessions: snap.sessions,
            totalTokens: result.sessions.reduce(0) { $0 + $1.totalTokens },
            runningCount: trueRunning, armedSessionIDs: armedIDs, armableSessionIDs: armable,
            usageGauges: gauges)
        lastUpdated = snapshot!.generatedAt
        publish(snapshot!)

        onScan?(UsageContextInputs(sessions: result.sessions, processes: processes,
                                   armableIDs: armable))
    }

    /// Last `maxLines` non-empty lines of a session's transcript, for the cutoff gate.
    nonisolated static func tailLines(forSessionID id: String, maxLines: Int = 40) -> [String] {
        let roots = [TranscriptSource.defaultCLIRoot, TranscriptSource.defaultDesktopRoot]
        for root in roots {
            if let url = findTranscript(id: id, under: root) {
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
                let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                return Array(lines.suffix(maxLines))
            }
        }
        return []
    }

    private nonisolated static func findTranscript(id: String, under root: URL) -> URL? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in e where url.lastPathComponent == "\(id).jsonl" { return url }
        return nil
    }
}
