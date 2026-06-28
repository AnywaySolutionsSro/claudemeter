import Foundation
import SwiftUI
import WidgetKit
import ClaudeMeterCore

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

    private let scanner: SessionScanner
    private let interval: TimeInterval
    private let snapshotStore = SnapshotStore()
    private var timer: Timer?
    private var isScanning = false

    /// Bundle id of the widget extension.
    static let widgetBundleID = "com.jakubzak.claudemeter.ClaudeMeterWidget"

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
            + ["running:\(snapshot.runningCount)", "total:\(snapshot.totalTokens)"]
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
            desktopDetector: DesktopAppProbe()
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
    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let result = await scanner.scan(now: Date())
        sessions = result.sessions
        snapshot = result.snapshot
        lastUpdated = result.snapshot.generatedAt

        // Publish for the widget + local copy (best-effort).
        publish(result.snapshot)
    }
}
