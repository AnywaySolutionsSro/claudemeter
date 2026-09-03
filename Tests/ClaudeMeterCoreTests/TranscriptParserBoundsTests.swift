@testable import ClaudeMeterCore
import Foundation
import Testing

/// The parser promises never to throw on malformed input — and a trapped
/// integer overflow is worse than a throw: one bad line would crash the app on
/// every launch (the scanner re-reads every file at start). Token fields are
/// therefore clamped to a sane range instead of trusted.
struct TranscriptParserBoundsTests {
    private let parser = TranscriptParser()

    @Test func absurdTokenCountsAreClampedNotTrapped() throws {
        let line = #"{"type":"assistant","message":{"usage":{"input_tokens":9223372036854775807,"output_tokens":1}}}"#
        let r = try #require(parser.parseLine(line))
        #expect(r.tokens.input == TranscriptParser.maxTokenField)
        #expect(r.tokens.output == 1)
        _ = r.tokens.total // must not trap
        _ = r.tokens + r.tokens
    }

    @Test func negativeTokenCountsBecomeZero() throws {
        let line = #"{"type":"assistant","message":{"usage":{"input_tokens":-5,"output_tokens":3}}}"#
        let r = try #require(parser.parseLine(line))
        #expect(r.tokens == TokenBreakdown(input: 0, output: 3))
    }
}
