import Foundation
import SwiftUI
import WidgetKit
import ClaudeMeterCore

/// Inputs the AppDelegate forwards to the AutoResumeCoordinator after each scan.
struct UsageContextInputs {
    let sessions: [SessionUsage]
    let processes: [LiveProcess]
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

    private let scanner: SessionScanner
    private let interval: TimeInterval
    private let snapshotStore = SnapshotStore()
    private let directProbe = LibprocProcessProbe()
    private let terminalDetectorForArmable = TerminalDetector()
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
            snapshotLimit: 12   // enough running sessions to fill the large widget
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

    /// Session IDs that may be armed: running, mapped to exactly one live process,
    /// whose owning terminal is iTerm2.
    func armableSessionIDs(sessions: [SessionUsage], processes: [LiveProcess]) -> [String] {
        let index = SessionProcessIndex(processes: processes)
        return sessions.compactMap { session in
            guard session.running == .running, let proc = index.process(forCwd: session.projectPath)
            else { return nil }
            let kind = terminalDetectorForArmable.detect(
                startPID: proc.pid,
                executablePathForPID: { LibprocProcessProbe.executablePathForPID($0) },
                parentPIDForPID: { LibprocProcessProbe.parentPIDForPID($0) })
            return kind.isDrivable ? session.id : nil
        }
    }

    /// Run one scan now and publish the results. Skips if a scan is in flight.
    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let result = await scanner.scan(now: Date())
        let processes = directProbe.liveClaudeProcesses()
        let armedIDs = armedIDsProvider?() ?? []

        sessions = result.sessions
        latestProcesses = processes
        let armable = armableSessionIDs(sessions: result.sessions, processes: processes)
        let snap = SessionSnapshot.make(
            from: result.sessions, now: result.snapshot.generatedAt,
            limit: 12, runningOnly: true, armedSessionIDs: armedIDs, armableSessionIDs: armable)
        snapshot = snap
        lastUpdated = snap.generatedAt
        publish(snap)

        onScan?(UsageContextInputs(sessions: result.sessions, processes: processes))
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
