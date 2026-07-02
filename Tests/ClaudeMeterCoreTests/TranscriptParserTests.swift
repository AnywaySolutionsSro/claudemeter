import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct TranscriptParserTests {
    private let parser = TranscriptParser()

    private let assistantLine = #"""
    {"type":"assistant","timestamp":"2026-06-28T17:49:06.352Z","cwd":"/Users/x/code","message":{"id":"msg_01ABC","model":"claude-opus-4-8","usage":{"input_tokens":28046,"cache_creation_input_tokens":19109,"cache_read_input_tokens":15840,"output_tokens":414}}}
    """#

    @Test func parsesAssistantUsage() throws {
        let r = try #require(parser.parseLine(assistantLine))
        #expect(r.model == "claude-opus-4-8")
        #expect(r.cwd == "/Users/x/code")
        #expect(r.tokens == TokenBreakdown(input: 28046, output: 414, cacheCreation: 19109, cacheRead: 15840))
        #expect(r.timestamp == ISODate.parse("2026-06-28T17:49:06.352Z"))
        #expect(r.messageID == "msg_01ABC")
    }

    @Test func missingMessageIDIsNil() throws {
        let line = #"{"type":"assistant","message":{"usage":{"output_tokens":5}}}"#
        let r = try #require(parser.parseLine(line))
        #expect(r.messageID == nil)
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

    // `<synthetic>` entries are error placeholders (e.g. the usage-limit cutoff),
    // not real API usage: never a record, never "malformed" — they'd otherwise
    // pollute the models list, lastActivity, and the malformed-line telemetry.
    @Test func syntheticEntriesAreSkippedNotMalformed() {
        let noUsage = #"{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your limit"}]}}"#
        let zeroUsage = #"{"type":"assistant","message":{"id":"msg_s","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        #expect(parser.parseLine(noUsage) == nil)
        #expect(parser.parseLine(zeroUsage) == nil)
        let parsed = parser.parse([noUsage, zeroUsage])
        #expect(parsed.records.isEmpty)
        #expect(parsed.malformedLineCount == 0)
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
