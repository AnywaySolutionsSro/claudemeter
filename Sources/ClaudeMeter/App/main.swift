import AppKit
import ClaudeMeterCore

// Headless smoke/diagnostic mode: scan local transcripts once, print a summary, and exit.
// Used to verify the sessions engine end-to-end without launching the menu-bar UI.
if CommandLine.arguments.contains("--dump-sessions") {
    let scanner = SessionScanner(
        discoverer: TranscriptSource(),
        processProbe: LibprocProcessProbe(),
        desktopDetector: DesktopAppProbe()
    )
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let result = await scanner.scan(now: Date())
        print("sessions: \(result.sessions.count)  running: \(result.snapshot.runningCount)  total: \(Formatting.tokenCount(result.snapshot.totalTokens))")
        for s in result.sessions.prefix(20) {
            let dot = s.running == .running ? "●" : "○"
            let origin = s.origin == .cli ? "CLI" : "APP"
            let burn = String(format: "%.0f", s.burnRate)
            print("\(dot) \(origin)  \(Formatting.tokenCount(s.totalTokens).padding(toLength: 6, withPad: " ", startingAt: 0))  +\(Formatting.tokenCount(s.cacheReadTokens)) cached  \(burn) t/m  \(s.projectName)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// Diagnostic: report where the widget snapshot resolves and whether writing works.
if CommandLine.arguments.contains("--snapshot-test") {
    let inbox = SessionMonitor.widgetInboxURL()
    FileHandle.standardError.write("widget inbox URL: \(inbox.path)\n".data(using: .utf8)!)
    let snapshot = SessionSnapshot.make(from: [], now: Date())
    let store = SnapshotStore()
    do { try store.write(snapshot, to: inbox); FileHandle.standardError.write("widget inbox write: OK\n".data(using: .utf8)!) }
    catch { FileHandle.standardError.write("widget inbox write FAILED: \(error)\n".data(using: .utf8)!) }
    exit(0)
}

// Menu-bar–only agent: no Dock icon, no main window, no Cmd-Tab entry.
// Top-level code is nonisolated, but it executes on the main thread, so we assume main-actor
// isolation to construct the @MainActor delegate. `run()` blocks here, keeping `delegate` alive.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
