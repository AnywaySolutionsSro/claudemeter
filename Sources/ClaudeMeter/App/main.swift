import AppKit
import ClaudeMeterCore

// Headless smoke/diagnostic mode: scan local transcripts once, print a summary, and exit.
// Used to verify the sessions engine end-to-end without launching the menu-bar UI.
if CommandLine.arguments.contains("--dump-sessions") {
    let scanner = SessionScanner(
        discoverer: TranscriptSource(),
        processProbe: LibprocProcessProbe(),
        desktopDetector: DesktopAppProbe(),
    )
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let result = await scanner.scan(now: Date())
        print(
            "sessions: \(result.sessions.count)  running: \(result.snapshot.runningCount)  total: \(Formatting.tokenCount(result.snapshot.totalTokens))",
        )
        for s in result.sessions.prefix(20) {
            let dot = s.running == .running ? "●" : "○"
            let origin = s.origin == .cli ? "CLI" : "APP"
            let burn = String(format: "%.0f", s.burnRate)
            print(
                "\(dot) \(origin)  \(Formatting.tokenCount(s.totalTokens).padding(toLength: 6, withPad: " ", startingAt: 0))  +\(Formatting.tokenCount(s.cacheReadTokens)) cached  \(burn) t/m  \(s.projectName)",
            )
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// Diagnostic: report where the widget snapshot resolves and whether writing works.
if CommandLine.arguments.contains("--snapshot-test") {
    let inbox = SessionMonitor.widgetInboxURL()
    FileHandle.standardError.write(Data("widget inbox URL: \(inbox.path)\n".utf8))
    let snapshot = SessionSnapshot.make(from: [], now: Date())
    let store = SnapshotStore()
    do {
        try store.write(snapshot, to: inbox)
        FileHandle.standardError.write(Data("widget inbox write: OK\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("widget inbox write FAILED: \(error)\n".utf8))
    }
    exit(0)
}

// Diagnostics: `--update-check` runs the updater's check + download + verification
// headlessly and prints every decision (nothing installed, staged bundle deleted).
// `--update-install` additionally performs the real swap + relaunch when the
// bundle is in place (quit the GUI instance first: `pkill -x ClaudeMeter`).
if CommandLine.arguments.contains("--update-check") || CommandLine.arguments.contains("--update-install") {
    let performInstall = CommandLine.arguments.contains("--update-install")
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let mode = UpdatePolicy.installMode(
        bundleURL: Bundle.main.bundleURL,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        canWriteParent: { FileManager.default.isWritableFile(atPath: $0.path) },
    )
    print("running: \(version)  bundle: \(Bundle.main.bundleURL.path)\ninstall mode: \(mode)")
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        defer { semaphore.signal() }
        do {
            let latest = try await GitHubReleaseClient().fetchLatest()
            let decision = UpdatePolicy.decide(current: AppVersion(version), latest: latest, skipped: nil)
            print("latest: \(latest?.tagName ?? "none")  decision: \(decision)")
            guard let latest else { return }
            let staged = try await UpdateInstaller().stage(latest) { print(String(
                format: "  download %3.0f%%",
                $0 * 100,
            )) }
            print("staged + verified: \(staged.path)")
            if performInstall, case let .inPlace(bundleURL) = mode, case .available = decision {
                print("installing over \(bundleURL.path) and relaunching…")
                try await UpdateInstaller().install(staged: staged, over: bundleURL)
                return
            }
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent())
        } catch {
            print("FAILED: \(error.localizedDescription)")
        }
    }
    semaphore.wait()
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
