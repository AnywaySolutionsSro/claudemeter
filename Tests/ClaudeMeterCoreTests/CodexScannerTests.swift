@testable import ClaudeMeterCore
import Foundation
import Testing

struct CodexScannerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let iTerm = "/Applications/iTerm.app/Contents/MacOS/iTerm2"

    private struct FakeProbe: ProcessProbing {
        var codex: [LiveProcess] = []
        func liveClaudeProcesses() -> [LiveProcess] { [] }
        func liveCodexProcesses() -> [LiveProcess] { codex }
    }

    /// Line indices stand in for byte offsets: `chunk(from: n)` returns the lines after index n.
    private final class FakeSource: CodexTranscriptDiscovering, @unchecked Sendable {
        var refs: [TranscriptRef]
        var linesByID: [String: [String]]
        var imported: Set<String> = []
        var failingIDs: Set<String> = []
        private(set) var chunkCalls: [String: [Int64]] = [:]

        init(refs: [TranscriptRef], linesByID: [String: [String]]) {
            self.refs = refs
            self.linesByID = linesByID
        }

        func discover() -> [TranscriptRef] { refs }
        func lines(of ref: TranscriptRef) -> [String] { linesByID[ref.id] ?? [] }
        func importedIDs() -> Set<String> { imported }
        func chunk(of ref: TranscriptRef, fromByteOffset offset: Int64) -> TranscriptChunk? {
            chunkCalls[ref.id, default: []].append(offset)
            guard !failingIDs.contains(ref.id) else { return nil }
            let all = linesByID[ref.id] ?? []
            guard offset <= Int64(all.count) else { return nil }
            return TranscriptChunk(lines: Array(all.dropFirst(Int(offset))), endOffset: Int64(all.count))
        }
    }

    private func ref(_ id: String, origin: SessionOrigin = .codexCLI, modified: TimeInterval = 1_000) -> TranscriptRef {
        TranscriptRef(id: id, url: URL(fileURLWithPath: "/tmp/rollout-\(id).jsonl"), origin: origin,
                      title: "t-\(id)", modifiedAt: Date(timeIntervalSince1970: modified))
    }

    private func meta(_ id: String, cwd: String, originator: String = "codex-tui", legacy: Bool = false) -> String {
        let mode = legacy ? #","history_mode":"legacy""# : ""
        return #"{"timestamp":"2026-11-27T10:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","originator":"\#(originator)"\#(mode)}}"#
    }

    private func model(_ name: String) -> String {
        #"{"timestamp":"2026-11-27T10:00:01Z","type":"turn_context","payload":{"model":"\#(name)"}}"#
    }

    private func tokens(_ output: Int, at time: String = "2026-11-27T10:01:00Z", limits: String = "null") -> String {
        #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":\#(output)}},"rate_limits":\#(limits)}}"#
    }

    /// A `token_count` with `info: null` — limits but no usage.
    private func limitsOnly(_ limits: String) -> String {
        #"{"timestamp":"2026-11-27T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":\#(limits)}}"#
    }

    private func limits(used: Double) -> String {
        #"{"limit_id":"codex","primary":{"used_percent":\#(used),"window_minutes":10080,"resets_at":1796332812},"secondary":null,"rate_limit_reached_type":null}"#
    }

    private func scanner(_ source: FakeSource, processes: [LiveProcess] = []) -> CodexScanner {
        CodexScanner(source: source, processProbe: FakeProbe(codex: processes),
                     canonicalize: { $0 },
                     executablePathForPID: { _ in Self.iTerm }, parentPIDForPID: { _ in 1 })
    }

    @Test func testDesktopSessionNeverArmable() async {
        let source = FakeSource(
            refs: [ref("tui"), ref("desk", origin: .codexDesktop)],
            linesByID: [
                "tui": [meta("tui", cwd: "/p1"), tokens(10)],
                "desk": [meta("desk", cwd: "/p2", originator: "Codex Desktop"), tokens(20)],
            ],
        )
        let procs = [
            LiveProcess(pid: 10, cwd: "/p1", tty: "/dev/ttys001", ppid: 1),
            LiveProcess(pid: 11, cwd: "/p2", tty: "/dev/ttys002", ppid: 1),
        ]
        let result = await scanner(source, processes: procs).scan(now: now)
        #expect(result.armableSessionIDs == ["tui"])
        #expect(result.sessions.first { $0.id == "desk" }?.running == .idle)
        #expect(result.sessions.first { $0.id == "tui" }?.running == .running)
        #expect(result.processes == procs)
    }

    @Test func testNonTUIOriginatorNotArmable() async {
        let source = FakeSource(refs: [ref("exec")],
                                linesByID: ["exec": [meta("exec", cwd: "/p1", originator: "codex_exec"), tokens(5)]])
        let procs = [LiveProcess(pid: 10, cwd: "/p1", tty: "/dev/ttys001", ppid: 1)]
        let result = await scanner(source, processes: procs).scan(now: now)
        #expect(result.sessions.first?.running == .running)
        #expect(result.armableSessionIDs.isEmpty)
    }

    @Test func testTwoProcessesInOneCwdNotArmable() async {
        let source = FakeSource(refs: [ref("a", modified: 2_000), ref("b")],
                                linesByID: ["a": [meta("a", cwd: "/p1"), tokens(5)],
                                            "b": [meta("b", cwd: "/p1"), tokens(6)]])
        let procs = [LiveProcess(pid: 10, cwd: "/p1", tty: "/dev/ttys001", ppid: 1),
                     LiveProcess(pid: 11, cwd: "/p1", tty: "/dev/ttys002", ppid: 1)]
        let result = await scanner(source, processes: procs).scan(now: now)
        #expect(result.sessions.allSatisfy { $0.running == .running })
        #expect(result.armableSessionIDs.isEmpty)
    }

    @Test func testIncrementalScanFoldsOnlyAppendedLines() async {
        let source = FakeSource(refs: [ref("s1")],
                                linesByID: ["s1": [meta("s1", cwd: "/p1"), model("gpt-5"), tokens(10)]])
        let scanner = scanner(source)
        let first = await scanner.scan(now: now)
        #expect(first.sessions.first?.tokens.output == 10)

        // Unchanged mtime: the file is not even opened.
        _ = await scanner.scan(now: now)
        #expect(source.chunkCalls["s1"] == [0])

        source.linesByID["s1", default: []].append(tokens(25, at: "2026-11-27T10:05:00Z"))
        source.refs = [ref("s1", modified: 2_000)]
        let second = await scanner.scan(now: now)
        #expect(source.chunkCalls["s1"] == [0, 3])
        let session = second.sessions.first
        #expect(session?.tokens.output == 25)
        #expect(session?.lastModel == "gpt-5")
        #expect(session?.projectPath == "/p1")
        #expect(session?.tool == .codex)
        #expect(session?.title == "t-s1")
    }

    @Test func testTruncatedFileRestartsFromZero() async {
        let source = FakeSource(refs: [ref("s1")],
                                linesByID: ["s1": [meta("s1", cwd: "/p1"), tokens(10), tokens(20)]])
        let scanner = scanner(source)
        _ = await scanner.scan(now: now)
        source.linesByID["s1"] = [meta("s1", cwd: "/p9"), tokens(3)]
        source.refs = [ref("s1", modified: 2_000)]
        let result = await scanner.scan(now: now)
        #expect(source.chunkCalls["s1"] == [0, 3, 0])
        #expect(result.sessions.first?.tokens.output == 3)
        #expect(result.sessions.first?.projectPath == "/p9")
    }

    @Test func testUnreadableFileKeepsCachedState() async {
        let source = FakeSource(refs: [ref("s1")], linesByID: ["s1": [meta("s1", cwd: "/p1"), tokens(10)]])
        let scanner = scanner(source)
        _ = await scanner.scan(now: now)
        source.failingIDs = ["s1"]
        source.refs = [ref("s1", modified: 2_000)]
        let result = await scanner.scan(now: now)
        #expect(result.sessions.first?.tokens.output == 10)
    }

    @Test func testImportedThreadsExcludedUntilTheyAccrueTokens() async {
        let importedLines = [meta("imp", cwd: "/p1", originator: "Codex Desktop", legacy: true),
                             #"{"timestamp":"2026-11-27T10:00:00Z","type":"response_item","payload":{}}"#]
        let source = FakeSource(refs: [ref("imp", origin: .codexDesktop)], linesByID: ["imp": importedLines])
        source.imported = ["imp"]
        let scanner = scanner(source)
        let first = await scanner.scan(now: now)
        #expect(first.sessions.isEmpty)
        #expect(first.isPresent == false)
        #expect(first.limits == nil)

        source.linesByID["imp", default: []].append(tokens(7, limits: limits(used: 12)))
        source.refs = [ref("imp", origin: .codexDesktop, modified: 2_000)]
        let second = await scanner.scan(now: now)
        #expect(second.sessions.map(\.id) == ["imp"])
        #expect(second.isPresent)
        #expect(second.limits?.windows.first?.usedPercent == 12)
    }

    @Test func testImportsFileAppearingLaterIsHonoured() async {
        let importedLines = [meta("imp", cwd: "/p1", originator: "Codex Desktop", legacy: true),
                             limitsOnly(limits(used: 50))]
        let source = FakeSource(refs: [ref("imp", origin: .codexDesktop)], linesByID: ["imp": importedLines])
        let scanner = scanner(source)
        // Imports file not written yet: indistinguishable from Codex work.
        #expect(await scanner.scan(now: now).isPresent)

        // The file appears; the transcript is unchanged (cached, not re-read).
        source.imported = ["imp"]
        let result = await scanner.scan(now: now)
        #expect(source.chunkCalls["imp"] == [0])
        #expect(result.sessions.isEmpty)
        #expect(result.isPresent == false)
        #expect(result.limits == nil)
    }

    @Test func testLimitsAreNewestAcrossSessionsAndSortedByTokens() async {
        let source = FakeSource(
            refs: [ref("a"), ref("b")],
            linesByID: [
                "a": [meta("a", cwd: "/p1"), tokens(10, at: "2026-11-27T11:00:00Z", limits: limits(used: 40))],
                "b": [meta("b", cwd: "/p2"), tokens(90, at: "2026-11-27T09:00:00Z", limits: limits(used: 5))],
            ],
        )
        let result = await scanner(source).scan(now: now)
        #expect(result.sessions.map(\.id) == ["b", "a"])
        #expect(result.limits?.windows.first?.usedPercent == 40)
        #expect(result.isPresent)
    }

    @Test func testZeroTokenSessionWithoutLimitsIsNotPresent() async {
        let source = FakeSource(refs: [ref("s1")], linesByID: ["s1": [meta("s1", cwd: "/p1")]])
        let result = await scanner(source).scan(now: now)
        #expect(result.sessions.map(\.id) == ["s1"])
        #expect(result.isPresent == false)
        #expect(result.limits == nil)
    }

    @Test func testEmptyDiscovery() async {
        let result = await scanner(FakeSource(refs: [], linesByID: [:])).scan(now: now)
        #expect(result == CodexScanResult(sessions: [], processes: [], armableSessionIDs: [],
                                          limits: nil, isPresent: false))
    }
}
