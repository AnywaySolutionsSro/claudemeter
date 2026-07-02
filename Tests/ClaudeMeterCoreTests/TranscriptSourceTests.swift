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

    @Test func cliDiscoversTopLevelTranscriptsAndSubagentsWithParentID() throws {
        defer { cleanup() }
        let cliRoot = root.appendingPathComponent("cli", isDirectory: true)
        let desktopRoot = root.appendingPathComponent("missing-desktop", isDirectory: true)

        let projA = cliRoot.appendingPathComponent("proj-a", isDirectory: true)
        let projB = cliRoot.appendingPathComponent("proj-b", isDirectory: true)
        try write("{}", to: projA.appendingPathComponent("sess-1.jsonl"))
        try write("{}", to: projB.appendingPathComponent("sess-2.jsonl"))
        // Subagent transcript: discovered, attributed to its parent session
        // (the directory above /subagents/).
        try write("{}", to: projA.appendingPathComponent("sess-1/subagents/agent-x.jsonl"))
        // Should be ignored: not a .jsonl file.
        try write("not json", to: projA.appendingPathComponent("notes.txt"))

        let source = TranscriptSource(cliRoot: cliRoot, desktopRoot: desktopRoot, fileManager: fm)
        let refs = source.discover()

        #expect(refs.allSatisfy { $0.origin == .cli })
        #expect(Set(refs.map(\.id)) == ["sess-1", "sess-2", "agent-x"])

        let parents = refs.filter { $0.parentID == nil }
        #expect(Set(parents.map(\.id)) == ["sess-1", "sess-2"])
        let subagent = try #require(refs.first { $0.id == "agent-x" })
        #expect(subagent.parentID == "sess-1")
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
        // Subagent transcript: discovered with its parent session id.
        let subagent = nested.appendingPathComponent("\(uuid)/subagents", isDirectory: true)
        try write("{}", to: subagent.appendingPathComponent("agent-y.jsonl"))

        let source = TranscriptSource(cliRoot: cliRoot, desktopRoot: desktopRoot, fileManager: fm)
        let refs = source.discover()

        #expect(refs.count == 2)
        let sub = try #require(refs.first { $0.id == "agent-y" })
        #expect(sub.parentID == uuid)
        #expect(sub.origin == .desktop)
        let ref = try #require(refs.first { $0.id == uuid })
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

    @Test func chunkReadsOnlyCompleteLinesAndReportsEndOffset() throws {
        defer { cleanup() }
        let cliRoot = root.appendingPathComponent("cli4", isDirectory: true)
        let file = cliRoot.appendingPathComponent("proj").appendingPathComponent("s.jsonl")
        try write("aa\nbb\npartial", to: file)

        let source = TranscriptSource(cliRoot: cliRoot,
                                      desktopRoot: root.appendingPathComponent("missing"), fileManager: fm)
        let ref = try #require(source.discover().first)
        let chunk = try #require(source.chunk(of: ref, fromByteOffset: 0))
        // Only lines terminated by \n are consumed; the partial tail stays unread.
        #expect(chunk.lines == ["aa", "bb"])
        #expect(chunk.endOffset == 6)
    }

    @Test func chunkFromOffsetReadsOnlyAppendedLines() throws {
        defer { cleanup() }
        let cliRoot = root.appendingPathComponent("cli5", isDirectory: true)
        let file = cliRoot.appendingPathComponent("proj").appendingPathComponent("s.jsonl")
        try write("aa\nbb\ncc\n", to: file)

        let source = TranscriptSource(cliRoot: cliRoot,
                                      desktopRoot: root.appendingPathComponent("missing"), fileManager: fm)
        let ref = try #require(source.discover().first)
        let chunk = try #require(source.chunk(of: ref, fromByteOffset: 3))
        #expect(chunk.lines == ["bb", "cc"])
        #expect(chunk.endOffset == 9)
        // Nothing new past the end -> empty chunk, offset unchanged.
        let empty = try #require(source.chunk(of: ref, fromByteOffset: 9))
        #expect(empty.lines.isEmpty)
        #expect(empty.endOffset == 9)
    }

    @Test func chunkBeyondFileSizeSignalsTruncation() throws {
        defer { cleanup() }
        let cliRoot = root.appendingPathComponent("cli6", isDirectory: true)
        let file = cliRoot.appendingPathComponent("proj").appendingPathComponent("s.jsonl")
        try write("aa\n", to: file)

        let source = TranscriptSource(cliRoot: cliRoot,
                                      desktopRoot: root.appendingPathComponent("missing"), fileManager: fm)
        let ref = try #require(source.discover().first)
        #expect(source.chunk(of: ref, fromByteOffset: 100) == nil)
    }

    @Test func linesKeepsEmptyIntermediateLines() throws {
        defer { cleanup() }
        let cliRoot = root.appendingPathComponent("cli3", isDirectory: true)
        let desktopRoot = root.appendingPathComponent("missing", isDirectory: true)
        let file = cliRoot.appendingPathComponent("proj").appendingPathComponent("s.jsonl")
        try write("a\n\nb\n", to: file)

        let source = TranscriptSource(cliRoot: cliRoot, desktopRoot: desktopRoot, fileManager: fm)
        let ref = try #require(source.discover().first)
        #expect(source.lines(of: ref) == ["a", "", "b"])
    }
}
