import Foundation
import SwiftUI
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

    /// Where the snapshot is published for the widget: the shared App Group
    /// container when available, else a local Application Support fallback.
    static func sharedSnapshotURL() -> URL {
        let fm = FileManager.default
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: SnapshotStore.appGroupID) {
            return group.appendingPathComponent("snapshot.json")
        }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeMeter", isDirectory: true)
        return base.appendingPathComponent("snapshot.json")
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

        // Publish for the widget (best-effort; ignore write failures).
        try? snapshotStore.write(result.snapshot, to: Self.sharedSnapshotURL())
    }
}
