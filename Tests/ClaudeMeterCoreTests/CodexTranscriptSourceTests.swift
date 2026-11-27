@testable import ClaudeMeterCore
import Foundation
import Testing

struct CodexTranscriptSourceTests {
    private let fm = FileManager.default
    private let home: URL

    init() throws {
        home = fm.temporaryDirectory
            .appendingPathComponent("CodexTranscriptSourceTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    private func cleanup() {
        try? fm.removeItem(at: home)
    }

    private func write(_ contents: String, to relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func copyFixture(_ url: URL, to relativeDir: String) throws {
        let dir = home.appendingPathComponent(relativeDir, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.copyItem(at: url, to: dir.appendingPathComponent(url.lastPathComponent))
    }

    @Test func discoversRolloutsRecursivelyWithIDsOriginsAndTitles() throws {
        defer { cleanup() }
        try copyFixture(CodexFixtures.tuiURL, to: "sessions/2026/11/26")
        try copyFixture(CodexFixtures.importedURL, to: "sessions/2026/11/27")
        // No session_meta first line: id falls back to the filename's uuid suffix.
        let bareID = "01a21d99-0000-7000-8000-000000000001"
        try write("{\"type\":\"event_msg\"}\n", to: "sessions/2026/11/27/rollout-2026-11-27T16-00-00-\(bareID).jsonl")
        // Ignored: not a rollout, not jsonl.
        try write("{}\n", to: "sessions/2026/11/27/other.jsonl")
        try write("{}\n", to: "sessions/2026/11/27/rollout-x.txt")
        try write("""
        {"id":"\(CodexFixtures.tuiSessionID)","thread_name":"Old name","updated_at":"2026-11-26T21:58:20Z"}
        not json
        {"id":"\(CodexFixtures.tuiSessionID)","thread_name":"Show render","updated_at":"2026-11-26T22:00:00Z"}
        """, to: "session_index.jsonl")

        let refs = CodexTranscriptSource(codexHome: home, fileManager: fm).discover()
        let byID = Dictionary(uniqueKeysWithValues: refs.map { ($0.id, $0) })

        #expect(Set(byID.keys) == [CodexFixtures.tuiSessionID, CodexFixtures.importedSessionID, bareID])
        #expect(byID[CodexFixtures.tuiSessionID]?.origin == .codexCLI)
        #expect(byID[CodexFixtures.tuiSessionID]?.title == "Show render")
        #expect(byID[CodexFixtures.importedSessionID]?.origin == .codexDesktop)
        #expect(byID[CodexFixtures.importedSessionID]?.title == nil)
        // No originator: not provably a terminal session, so never resumable.
        #expect(byID[bareID]?.origin == .codexDesktop)
        #expect(refs.allSatisfy { $0.parentID == nil })
    }

    @Test func testOnlyCodexTUIOriginatorIsTerminal() throws {
        defer { cleanup() }
        let cases = ["codex-tui": SessionOrigin.codexCLI, "Codex Desktop": .codexDesktop,
                     "codex_exec": .codexDesktop, "codex_vscode": .codexDesktop]
        for (index, originator) in cases.keys.sorted().enumerated() {
            let id = "01a21d99-0000-7000-8000-00000000001\(index)"
            try write("""
            {"type":"session_meta","payload":{"id":"\(id)","originator":"\(originator)"}}\n
            """, to: "sessions/2026/11/27/rollout-2026-11-27T16-00-0\(index)-\(id).jsonl")
        }
        let refs = CodexTranscriptSource(codexHome: home, fileManager: fm).discover()
        let origins = try Dictionary(uniqueKeysWithValues: refs.map { ref in
            let line = try #require(TranscriptFileReader.firstLine(of: ref.url))
            let originator = cases.keys.first { line.contains("\"\($0)\"") }
            return try (#require(originator), ref.origin)
        })
        #expect(origins == cases)
    }

    @Test func missingHomeDiscoversNothing() {
        let source = CodexTranscriptSource(codexHome: home.appendingPathComponent("nope"), fileManager: fm)
        #expect(source.discover().isEmpty)
        #expect(source.importedIDs().isEmpty)
    }

    @Test func importedIDsReadFromImportsFile() throws {
        defer { cleanup() }
        try write("""
        {"records":[{"source_path":"/x.jsonl","imported_thread_id":"a"},\
        {"imported_thread_id":"b"},{"title":"no id"}]}
        """, to: "external_agent_session_imports.json")
        #expect(CodexTranscriptSource(codexHome: home, fileManager: fm).importedIDs() == ["a", "b"])
    }

    @Test func malformedImportsFileYieldsNothing() throws {
        defer { cleanup() }
        try write("[1,2]", to: "external_agent_session_imports.json")
        #expect(CodexTranscriptSource(codexHome: home, fileManager: fm).importedIDs().isEmpty)
    }

    @Test func linesAndChunksReadTheTranscript() throws {
        defer { cleanup() }
        try write(
            "{\"a\":1}\n{\"b\":2}\n{\"c\":",
            to: "sessions/2026/11/27/rollout-t-01a21d99-0000-7000-8000-000000000002.jsonl",
        )
        let source = CodexTranscriptSource(codexHome: home, fileManager: fm)
        let ref = try #require(source.discover().first)
        #expect(source.lines(of: ref).count == 3)
        let chunk = try #require(source.chunk(of: ref, fromByteOffset: 0))
        #expect(chunk.lines == ["{\"a\":1}", "{\"b\":2}"])
        #expect(chunk.endOffset == 16)
        #expect(source.chunk(of: ref, fromByteOffset: 999) == nil)
    }

    @Test func defaultHomeIsDotCodex() {
        #expect(CodexTranscriptSource.defaultHome.path.hasSuffix("/.codex"))
    }
}
