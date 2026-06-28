import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct TranscriptSourceTests {
    private let fm = FileManager.default
    private let root: URL

    init() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("TranscriptSourceTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // Best-effort cleanup of the per-test temp tree.
    private func cleanup() {
        try? fm.removeItem(at: root)
    }

    private func mkdir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func write(_ contents: String, to url: URL) throws {
        try mkdir(url.deletingLastPathComponent())
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func cliDiscoversTopLevelTranscriptsAndIgnoresSubagents() throws {
        defer { cleanup() }
        let cliRoot = root.appendingPathComponent("cli", isDirectory: true)
        let desktopRoot = root.appendingPathComponent("missing-desktop", isDirectory: true)

        let projA = cliRoot.appendingPathComponent("proj-a", isDirectory: true)
        let projB = cliRoot.appendingPathComponent("proj-b", isDirectory: true)
        try write("{}", to: projA.appendingPathComponent("sess-1.jsonl"))
        try write("{}", to: projB.appendingPathComponent("sess-2.jsonl"))
        // Should be ignored: lives under a /subagents/ component.
        try write("{}", to: projA.appendingPathComponent("subagents/agent-x.jsonl"))
        // Should be ignored: not a .jsonl file.
        try write("not json", to: projA.appendingPathComponent("notes.txt"))

        let source = TranscriptSource(cliRoot: cliRoot, desktopRoot: desktopRoot, fileManager: fm)
        let refs = source.discover()

        #expect(refs.allSatisfy { $0.origin == .cli })
        #expect(Set(refs.map(\.id)) == ["sess-1", "sess-2"])
        #expect(!refs.map(\.id).contains("agent-x"))
    }

    @Test func desktopDiscoversNestedClaudeProjectsAndIgnoresOthers() throws {
        defer { cleanup() }
        let cliRoot = root.appendingPathComponent("missing-cli", isDirectory: true)
        let desktopRoot = root.appendingPathComponent("desktop", isDirectory: true)

        let uuid = UUID().uuidString
        let nested = desktopRoot
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("proj", isDirectory: true)
        try write("{}", to: nested.appendingPathComponent("\(uuid).jsonl"))
        // Should be ignored: not under a /.claude/projects/ path.
        try write("{}", to: desktopRoot.appendingPathComponent("loose/other.jsonl"))
        // Should be ignored: under /subagents/.
        let subagent = nested.appendingPathComponent("subagents", isDirectory: true)
        try write("{}", to: subagent.appendingPathComponent("agent-y.jsonl"))

        let source = TranscriptSource(cliRoot: cliRoot, desktopRoot: desktopRoot, fileManager: fm)
        let refs = source.discover()

        #expect(refs.count == 1)
        let ref = try #require(refs.first)
        #expect(ref.origin == .desktop)
        #expect(ref.id == uuid)
    }

    @Test func missingRootsYieldEmpty() {
        let cliRoot = root.appendingPathComponent("nope-cli", isDirectory: true)
        let desktopRoot = root.appendingPathComponent("nope-desktop", isDirectory: true)
        let source = TranscriptSource(cliRoot: cliRoot, desktopRoot: desktopRoot, fileManager: fm)
        #expect(source.discover().isEmpty)
    }

    @Test func linesReturnsFileLinesDroppingTrailingNewline() throws {
        defer { cleanup() }
        let cliRoot = root.appendingPathComponent("cli2", isDirectory: true)
        let desktopRoot = root.appendingPathComponent("missing", isDirectory: true)
        let file = cliRoot.appendingPathComponent("proj").appendingPathComponent("s.jsonl")
        try write("line1\nline2\nline3\n", to: file)

        let source = TranscriptSource(cliRoot: cliRoot, desktopRoot: desktopRoot, fileManager: fm)
        let ref = try #require(source.discover().first)
        #expect(source.lines(of: ref) == ["line1", "line2", "line3"])
    }
}
