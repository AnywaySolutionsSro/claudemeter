import AppKit
import ClaudeMeterCore
import Foundation
import os

/// Downloads a release, proves it is ours, and swaps it in for the running app.
///
/// Two phases so the caller can drive UI state between them:
///
/// 1. `stage(_:progress:)` — download `ClaudeMeter.zip` (+ `.sha256`), verify the
///    checksum, unpack with `ditto` (keeps the signature and the notarization
///    staple intact), and run `BundleVerifier`. Any failure removes the temp
///    directory and throws; nothing on disk outside the temp dir is touched.
/// 2. `install(staged:over:)` — swap the staged bundle in for the installed one
///    (`replaceItemAt`, so the installed path is never empty; the running binary stays
///    alive by inode), trash the old bundle, re-register with LaunchServices so the
///    widget appex doesn't linger on a stale registration, then relaunch.
struct UpdateInstaller: Sendable {
    var client = GitHubReleaseClient()
    private let log = Logger(subsystem: "com.jakubzak.claudemeter", category: "updater")

    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
        + "LaunchServices.framework/Support/lsregister"

    // MARK: - Stage

    func stage(_ release: ReleaseInfo, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeMeterUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        do {
            let bundle = try await stage(release, in: workDir, progress: progress)
            log.notice("staged \(release.tagName, privacy: .public) at \(bundle.path, privacy: .public)")
            return bundle
        } catch {
            try? FileManager.default.removeItem(at: workDir)
            log
                .error(
                    "staging \(release.tagName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)",
                )
            throw error
        }
    }

    private func stage(
        _ release: ReleaseInfo,
        in workDir: URL,
        progress: @escaping @Sendable (Double) -> Void,
    ) async throws -> URL {
        let archive = workDir.appendingPathComponent(ReleaseDecoder.archiveName)
        try await client.download(
            release.archiveURL,
            to: archive,
            expectedSize: release.archiveSize,
            progress: progress,
        )

        if let checksumURL = release.checksumURL {
            let manifest = try await client.fetchText(checksumURL)
            guard let expected = Sha256Manifest.digest(in: manifest, for: ReleaseDecoder.archiveName) else {
                throw UpdateError.checksumMalformed
            }
            let data = try Data(contentsOf: archive, options: .mappedIfSafe)
            guard Sha256Manifest.matches(expected: expected, data: data) else { throw UpdateError.checksumMismatch }
        }

        let unpacked = workDir.appendingPathComponent("unpacked", isDirectory: true)
        let result = Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        guard result.status == 0 else { throw UpdateError.unpackFailed(result.output) }

        let bundle = unpacked.appendingPathComponent("ClaudeMeter.app")
        guard FileManager.default.fileExists(atPath: bundle.path) else { throw UpdateError.bundleMissing }
        try BundleVerifier.verify(bundleURL: bundle, expectedVersion: release.version)
        return bundle
    }

    // MARK: - Install

    /// Replaces `target` with `staged` and relaunches. Only returns by throwing.
    /// `async` so the blocking `lsregister`/`killall` calls run off the main actor.
    ///
    /// Crash-safe ordering: the staged bundle is first moved *next to* the target
    /// (same directory, so the write permission is proven before the installed app
    /// is touched), then `replaceItemAt` swaps it in — the installed app is either
    /// the old or the new bundle at every instant, never absent. The old bundle is
    /// kept as a backup through the swap and only trashed afterwards.
    func install(staged: URL, over target: URL) async throws {
        let fm = FileManager.default
        let directory = target.deletingLastPathComponent()
        let incoming = directory.appendingPathComponent(".\(target.lastPathComponent).update")
        let backupName = "\(target.lastPathComponent).previous"
        let workDir = staged.deletingLastPathComponent().deletingLastPathComponent()
        try? fm.removeItem(at: incoming)
        do {
            try fm.moveItem(at: staged, to: incoming)
        } catch {
            try? fm.removeItem(at: workDir)
            throw UpdateError
                .installFailed("couldn't place the new app next to the installed one: \(error.localizedDescription)")
        }
        do {
            _ = try fm.replaceItemAt(
                target, withItemAt: incoming, backupItemName: backupName,
                options: [.usingNewMetadataOnly, .withoutDeletingBackupItem],
            )
        } catch {
            try? fm.removeItem(at: incoming)
            try? fm.removeItem(at: workDir)
            throw UpdateError.installFailed(error.localizedDescription)
        }
        // The backup must not linger next to the app: it is a second registered copy
        // of the app AND the widget appex under the same bundle ids, which is exactly
        // what makes the widget flip to a stale path. Trash it, or delete it outright.
        let backup = directory.appendingPathComponent(backupName)
        do {
            try fm.trashItem(at: backup, resultingItemURL: nil)
        } catch {
            log
                .notice(
                    "couldn't trash the previous app, deleting instead: \(error.localizedDescription, privacy: .public)",
                )
            try? fm.removeItem(at: backup)
        }
        try? fm.removeItem(at: workDir)

        // Same consolidation as `build.sh --install`: one registration, at this path.
        _ = Self.run(Self.lsregister, ["-f", target.path])
        _ = Self.run("/usr/bin/killall", ["chronod"])
        log.notice("installed \(target.path, privacy: .public); relaunching")
        Self.relaunch(bundleURL: target)
    }

    /// A detached shell waits for this process to exit, then opens the new bundle.
    /// Children survive the parent's exit, so terminating ourselves next is safe.
    ///
    /// `open -n` + retry, not a plain `open`: LaunchServices keeps the just-exited
    /// process on its running list for a few tens of ms after the kernel reaped it.
    /// A plain `open` in that window resolves to the dead instance, tries to
    /// activate it, fails with -600 procNotFound and launches nothing (seen in the
    /// wild on 2026-08-29). `-n` asks for a new instance regardless, and retrying
    /// until `open` exits 0 covers the window. Bounded so a broken bundle cannot
    /// leave a shell polling forever.
    private static func relaunch(bundleURL: URL) {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        i=0
        while [ "$i" -lt 30 ]; do
          /bin/sleep 0.5
          if /usr/bin/open -n "$2"; then exit 0; fi
          i=$((i + 1))
        done
        exit 1
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "_", String(ProcessInfo.processInfo.processIdentifier), bundleURL.path]
        try? process.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    // MARK: - Helpers

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
        )
    }
}
