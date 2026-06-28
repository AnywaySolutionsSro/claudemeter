import Testing
@testable import ClaudeMeterCore

@Suite struct ProcessProbeTests {
    @Test func tallyGroupsAndCountsByCwd() {
        let counts = LibprocProcessProbe.tally([1: "/a", 2: "/a", 3: "/b"])
        #expect(counts == ["/a": 2, "/b": 1])
    }

    @Test func tallyOfEmptyIsEmpty() {
        #expect(LibprocProcessProbe.tally([:]).isEmpty)
    }

    @Test func recognisesClaudeCodeExecutablePaths() {
        #expect(LibprocProcessProbe.isClaudeCodeExecutable("/Users/x/.local/share/claude/versions/2.1.195"))
        #expect(LibprocProcessProbe.isClaudeCodeExecutable("/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"))
    }

    @Test func rejectsUnrelatedAndSelfPaths() {
        #expect(!LibprocProcessProbe.isClaudeCodeExecutable("/usr/bin/node"))
        #expect(!LibprocProcessProbe.isClaudeCodeExecutable("/Applications/Safari.app/Contents/MacOS/Safari"))
        // Must not match our own app, whose name contains "claude".
        #expect(!LibprocProcessProbe.isClaudeCodeExecutable("/Applications/ClaudeMeter.app/Contents/MacOS/ClaudeMeter"))
    }

    @Test func liveCountsAreAlwaysPositive() {
        // Smoke test: the environment may have zero `claude` processes, so we
        // do NOT assert non-emptiness — only that every reported count is >= 1.
        let counts = LibprocProcessProbe().liveClaudeCwdCounts()
        for (_, count) in counts {
            #expect(count >= 1)
        }
    }
}
