import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct SessionScannerTests {
    // now is well after the 2026 timestamps used in the fixture lines.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct FakeProbe: ProcessProbing {
        let counts: [String: Int]
        func liveClaudeCwdCounts() -> [String: Int] { counts }
    }

    private struct FakeDesktop: DesktopAppDetecting {
        let running: Bool
        func isClaudeDesktopRunning() -> Bool { running }
    }

    private final class FakeDiscoverer: TranscriptDiscovering, @unchecked Sendable {
        let refs: [TranscriptRef]
        let linesByID: [String: [String]]
        private(set) var lineCalls: [String: Int] = [:]
        init(refs: [TranscriptRef], linesByID: [String: [String]]) {
            self.refs = refs
            self.linesByID = linesByID
        }
        func discover() -> [TranscriptRef] { refs }
        func lines(of ref: TranscriptRef) -> [String] {
            lineCalls[ref.id, default: 0] += 1
            return linesByID[ref.id] ?? []
        }
    }

    private func ref(_ id: String, origin: SessionOrigin = .cli, modified: TimeInterval = 1_000) -> TranscriptRef {
        TranscriptRef(id: id, url: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
                      origin: origin, title: nil, modifiedAt: Date(timeIntervalSince1970: modified))
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
        _ = await scanner.scan(now: now)
        // Second scan must NOT re-read the unchanged file.
        #expect(disco.lineCalls["s1"] == 1)
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
