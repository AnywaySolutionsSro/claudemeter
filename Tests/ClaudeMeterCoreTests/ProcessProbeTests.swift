@testable import ClaudeMeterCore
import Testing

struct ProcessProbeTests {
    // MARK: tally(processes:) — migrated from old tally([pid: cwd]) signature

    @Test func tallyGroupsAndCountsByCwd() {
        let counts = LibprocProcessProbe.tally(processes: [
            LiveProcess(pid: 1, cwd: "/a", tty: nil, ppid: 1),
            LiveProcess(pid: 2, cwd: "/a", tty: nil, ppid: 1),
            LiveProcess(pid: 3, cwd: "/b", tty: nil, ppid: 1),
        ])
        #expect(counts == ["/a": 2, "/b": 1])
    }

    @Test func tallyOfEmptyIsEmpty() {
        #expect(LibprocProcessProbe.tally(processes: []).isEmpty)
    }

    // MARK: defaulted liveClaudeCwdCounts() derives from liveClaudeProcesses()

    @Test func defaultCwdCountsDerivesFromProcesses() {
        struct Fake: ProcessProbing {
            func liveClaudeProcesses() -> [LiveProcess] {
                [LiveProcess(pid: 1, cwd: "/x", tty: "/dev/ttys001", ppid: 9),
                 LiveProcess(pid: 2, cwd: "/x", tty: "/dev/ttys002", ppid: 9)]
            }
        }
        #expect(Fake().liveClaudeCwdCounts() == ["/x": 2])
    }

    // MARK: isClaudeCodeExecutable — unchanged

    @Test func recognisesClaudeCodeExecutablePaths() {
        #expect(LibprocProcessProbe.isClaudeCodeExecutable("/Users/x/.local/share/claude/versions/2.1.195"))
        #expect(LibprocProcessProbe
            .isClaudeCodeExecutable("/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"))
    }

    @Test func rejectsUnrelatedAndSelfPaths() {
        #expect(!LibprocProcessProbe.isClaudeCodeExecutable("/usr/bin/node"))
        #expect(!LibprocProcessProbe.isClaudeCodeExecutable("/Applications/Safari.app/Contents/MacOS/Safari"))
        // Must not match our own app, whose name contains "claude".
        #expect(!LibprocProcessProbe.isClaudeCodeExecutable("/Applications/ClaudeMeter.app/Contents/MacOS/ClaudeMeter"))
    }

    // MARK: smoke test

    @Test func liveCountsAreAlwaysPositive() {
        // Smoke test: the environment may have zero `claude` processes, so we
        // do NOT assert non-emptiness — only that every reported count is >= 1.
        let counts = LibprocProcessProbe().liveClaudeCwdCounts()
        for (_, count) in counts {
            #expect(count >= 1)
        }
    }
}
