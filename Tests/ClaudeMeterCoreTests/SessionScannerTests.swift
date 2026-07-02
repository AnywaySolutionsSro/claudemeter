import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct SessionScannerTests {
    // now is well after the 2026 timestamps used in the fixture lines.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct FakeProbe: ProcessProbing {
        let counts: [String: Int]
        func liveClaudeProcesses() -> [LiveProcess] {
            var pid: Int32 = 100
            return counts.flatMap { (cwd, n) -> [LiveProcess] in
                (0..<n).map { _ in
                    let p = LiveProcess(pid: pid, cwd: cwd, tty: nil, ppid: 1)
                    pid += 1
                    return p
                }
            }
        }
    }

    private struct FakeDesktop: DesktopAppDetecting {
        let running: Bool
        func isClaudeDesktopRunning() -> Bool { running }
    }

    /// Byte offsets are opaque to the scanner, so this fake uses line indices as
    /// offsets: chunk(from: n) returns the lines after index n.
    private final class FakeDiscoverer: TranscriptDiscovering, @unchecked Sendable {
        var refs: [TranscriptRef]
        var linesByID: [String: [String]]
        private(set) var lineCalls: [String: Int] = [:]
        private(set) var chunkCalls: [String: [Int64]] = [:]
        init(refs: [TranscriptRef], linesByID: [String: [String]]) {
            self.refs = refs
            self.linesByID = linesByID
        }
        func discover() -> [TranscriptRef] { refs }
        func lines(of ref: TranscriptRef) -> [String] {
            lineCalls[ref.id, default: 0] += 1
            return linesByID[ref.id] ?? []
        }
        func chunk(of ref: TranscriptRef, fromByteOffset offset: Int64) -> TranscriptChunk? {
            chunkCalls[ref.id, default: []].append(offset)
            let all = linesByID[ref.id] ?? []
            guard offset <= Int64(all.count) else { return nil }  // truncation
            return TranscriptChunk(lines: Array(all.dropFirst(Int(offset))),
                                   endOffset: Int64(all.count))
        }
    }

    private func ref(_ id: String, origin: SessionOrigin = .cli, modified: TimeInterval = 1_000,
                     parentID: String? = nil) -> TranscriptRef {
        TranscriptRef(id: id, url: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
                      origin: origin, title: nil, modifiedAt: Date(timeIntervalSince1970: modified),
                      parentID: parentID)
    }

    private func line(cwd: String, output: Int) -> String {
        #"{"type":"assistant","timestamp":"2026-06-28T17:00:00Z","cwd":"\#(cwd)","message":{"model":"m","usage":{"output_tokens":\#(output)}}}"#
    }

    @Test func aggregatesAndSortsByTotalDescending() async {
        let disco = FakeDiscoverer(
            refs: [ref("s1"), ref("s2")],
            linesByID: ["s1": [line(cwd: "/p1", output: 100)], "s2": [line(cwd: "/p2", output: 300)]]
        )
        let scanner = SessionScanner(discoverer: disco, processProbe: FakeProbe(counts: [:]),
                                     desktopDetector: FakeDesktop(running: false))
        let result = await scanner.scan(now: now)
        #expect(result.sessions.map(\.id) == ["s2", "s1"])
        #expect(result.snapshot.totalTokens == 400)
        #expect(result.snapshot.runningCount == 0)
    }

    @Test func appliesRunningResolution() async {
        let disco = FakeDiscoverer(
            refs: [ref("s1")],
            linesByID: ["s1": [line(cwd: "/p1", output: 100)]]
        )
        let scanner = SessionScanner(discoverer: disco, processProbe: FakeProbe(counts: ["/p1": 1]),
                                     desktopDetector: FakeDesktop(running: false))
        let result = await scanner.scan(now: now)
        #expect(result.sessions.first?.running == .running)
        #expect(result.snapshot.runningCount == 1)
    }

    @Test func reusesCacheForUnchangedFiles() async {
        let disco = FakeDiscoverer(
            refs: [ref("s1", modified: 5_000)],
            linesByID: ["s1": [line(cwd: "/p1", output: 100)]]
        )
        let scanner = SessionScanner(discoverer: disco, processProbe: FakeProbe(counts: [:]),
                                     desktopDetector: FakeDesktop(running: false))
        _ = await scanner.scan(now: now)
        let second = await scanner.scan(now: now)
        // Second scan must NOT re-read the unchanged file — but still report it.
        #expect(disco.chunkCalls["s1"] == [0])
        #expect(second.sessions.first?.totalTokens == 100)
    }

    @Test func changedFileIsResumedFromCachedOffsetNotReRead() async {
        let disco = FakeDiscoverer(
            refs: [ref("s1", modified: 5_000)],
            linesByID: ["s1": [line(cwd: "/p1", output: 100)]]
        )
        let scanner = SessionScanner(discoverer: disco, processProbe: FakeProbe(counts: [:]),
                                     desktopDetector: FakeDesktop(running: false))
        _ = await scanner.scan(now: now)

        // The session appends one line; only that line may be read.
        disco.linesByID["s1"] = [line(cwd: "/p1", output: 100), line(cwd: "/p1", output: 40)]
        disco.refs = [ref("s1", modified: 6_000)]
        let result = await scanner.scan(now: now)

        #expect(result.sessions.first?.totalTokens == 140)
        #expect(disco.chunkCalls["s1"] == [0, 1])  // resumed from offset 1, never re-read line 0
    }

    @Test func truncatedFileFallsBackToFullReparse() async {
        let disco = FakeDiscoverer(
            refs: [ref("s1", modified: 5_000)],
            linesByID: ["s1": [line(cwd: "/p1", output: 100), line(cwd: "/p1", output: 40)]]
        )
        let scanner = SessionScanner(discoverer: disco, processProbe: FakeProbe(counts: [:]),
                                     desktopDetector: FakeDesktop(running: false))
        _ = await scanner.scan(now: now)

        // File shrank (rewrite): resuming from offset 2 fails -> reparse from 0.
        disco.linesByID["s1"] = [line(cwd: "/p1", output: 7)]
        disco.refs = [ref("s1", modified: 6_000)]
        let result = await scanner.scan(now: now)

        #expect(result.sessions.first?.totalTokens == 7)
        #expect(disco.chunkCalls["s1"] == [0, 2, 0])
    }

    @Test func subagentUsageFoldsIntoParentSession() async {
        let disco = FakeDiscoverer(
            refs: [ref("s1"), ref("agent-1", parentID: "s1")],
            linesByID: [
                "s1": [line(cwd: "/p1", output: 100)],
                "agent-1": [line(cwd: "/p1-worktree", output: 40)],
            ]
        )
        let scanner = SessionScanner(discoverer: disco, processProbe: FakeProbe(counts: [:]),
                                     desktopDetector: FakeDesktop(running: false))
        let result = await scanner.scan(now: now)
        // One session: the subagent's tokens belong to its parent.
        #expect(result.sessions.map(\.id) == ["s1"])
        #expect(result.sessions.first?.totalTokens == 140)
        // The parent transcript's cwd wins for process matching.
        #expect(result.sessions.first?.projectPath == "/p1")
    }

    @Test func subagentWithoutParentTranscriptIsIgnored() async {
        let disco = FakeDiscoverer(
            refs: [ref("agent-orphan", parentID: "gone")],
            linesByID: ["agent-orphan": [line(cwd: "/p1", output: 40)]]
        )
        let scanner = SessionScanner(discoverer: disco, processProbe: FakeProbe(counts: [:]),
                                     desktopDetector: FakeDesktop(running: false))
        let result = await scanner.scan(now: now)
        #expect(result.sessions.isEmpty)
    }

    // The transcript records a cwd as typed (possibly through symlinks); the
    // probe reads the kernel-resolved cwd. Both sides must match canonically or
    // a symlinked project shows permanently idle.
    @Test func sessionCwdIsCanonicalizedForProcessMatching() async {
        let disco = FakeDiscoverer(
            refs: [ref("s1")],
            linesByID: ["s1": [line(cwd: "/tmp/p1", output: 10)]]
        )
        let scanner = SessionScanner(
            discoverer: disco, processProbe: FakeProbe(counts: ["/private/tmp/p1": 1]),
            desktopDetector: FakeDesktop(running: false),
            canonicalize: { $0 == "/tmp/p1" ? "/private/tmp/p1" : $0 })
        let result = await scanner.scan(now: now)
        #expect(result.sessions.first?.projectPath == "/private/tmp/p1")
        #expect(result.sessions.first?.running == .running)
    }

    @Test func runningRankUsesFileMtimeNotAssistantTimestamp() async {
        // Both sessions share a cwd with ONE live process. "stale" has the newer
        // assistant timestamp; "fresh" has the newer file mtime and must win.
        let staleLine = #"{"type":"assistant","timestamp":"2026-06-28T17:00:00Z","cwd":"/p1","message":{"model":"m","usage":{"output_tokens":5}}}"#
        let freshLine = #"{"type":"assistant","timestamp":"2026-06-28T16:00:00Z","cwd":"/p1","message":{"model":"m","usage":{"output_tokens":5}}}"#
        let disco = FakeDiscoverer(
            refs: [ref("stale", modified: 1_000), ref("fresh", modified: 2_000)],
            linesByID: ["stale": [staleLine], "fresh": [freshLine]]
        )
        let scanner = SessionScanner(discoverer: disco, processProbe: FakeProbe(counts: ["/p1": 1]),
                                     desktopDetector: FakeDesktop(running: false))
        let result = await scanner.scan(now: now)
        #expect(result.sessions.first { $0.id == "fresh" }?.running == .running)
        #expect(result.sessions.first { $0.id == "stale" }?.running == .idle)
    }

    @Test func emptyDiscoveryYieldsEmptyResult() async {
        let disco = FakeDiscoverer(refs: [], linesByID: [:])
        let scanner = SessionScanner(discoverer: disco, processProbe: FakeProbe(counts: [:]),
                                     desktopDetector: FakeDesktop(running: false))
        let result = await scanner.scan(now: now)
        #expect(result.sessions.isEmpty)
        #expect(result.snapshot.totalTokens == 0)
    }

    @Test func derivesProjectPathFromTranscriptCwd() async {
        let disco = FakeDiscoverer(
            refs: [ref("s1")],
            linesByID: ["s1": [line(cwd: "/Users/x/code/movixtar", output: 10)]]
        )
        let scanner = SessionScanner(discoverer: disco, processProbe: FakeProbe(counts: [:]),
                                     desktopDetector: FakeDesktop(running: false))
        let result = await scanner.scan(now: now)
        #expect(result.sessions.first?.projectPath == "/Users/x/code/movixtar")
        #expect(result.sessions.first?.projectName == "movixtar")
    }
}
