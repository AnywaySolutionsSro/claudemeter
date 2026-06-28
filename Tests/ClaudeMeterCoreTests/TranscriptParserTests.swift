import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct TranscriptParserTests {
    private let parser = TranscriptParser()

    private let assistantLine = #"""
    {"type":"assistant","timestamp":"2026-06-28T17:49:06.352Z","cwd":"/Users/x/code","message":{"model":"claude-opus-4-8","usage":{"input_tokens":28046,"cache_creation_input_tokens":19109,"cache_read_input_tokens":15840,"output_tokens":414}}}
    """#

    @Test func parsesAssistantUsage() throws {
        let r = try #require(parser.parseLine(assistantLine))
        #expect(r.model == "claude-opus-4-8")
        #expect(r.cwd == "/Users/x/code")
        #expect(r.tokens == TokenBreakdown(input: 28046, output: 414, cacheCreation: 19109, cacheRead: 15840))
        #expect(r.timestamp == ISODate.parse("2026-06-28T17:49:06.352Z"))
    }

    @Test func ignoresNonAssistantLines() {
        #expect(parser.parseLine(#"{"type":"user","message":{"content":"hi"}}"#) == nil)
        #expect(parser.parseLine(#"{"type":"mode","mode":"normal"}"#) == nil)
    }

    @Test func ignoresBlankAndGarbageLines() {
        #expect(parser.parseLine("") == nil)
        #expect(parser.parseLine("   ") == nil)
        #expect(parser.parseLine("not json at all") == nil)
        #expect(parser.parseLine("{ broken json") == nil)
    }

    @Test func assistantWithoutUsageIsNil() {
        #expect(parser.parseLine(#"{"type":"assistant","message":{"model":"m"}}"#) == nil)
    }

    @Test func missingTokenFieldsDefaultToZero() throws {
        let line = #"{"type":"assistant","message":{"usage":{"output_tokens":5}}}"#
        let r = try #require(parser.parseLine(line))
        #expect(r.tokens == TokenBreakdown(input: 0, output: 5, cacheCreation: 0, cacheRead: 0))
    }

    @Test func parseCollectsRecordsAndCountsMalformed() {
        let lines = [
            assistantLine,
            "",                                                  // blank: ignored, not malformed
            #"{"type":"user"}"#,                                 // non-assistant: ignored, not malformed
            #"{"type":"assistant","message":{"model":"m"}}"#,   // assistant w/o usage: malformed
            assistantLine,
        ]
        let parsed = parser.parse(lines)
        #expect(parsed.records.count == 2)
        #expect(parsed.malformedLineCount == 1)
    }
}
