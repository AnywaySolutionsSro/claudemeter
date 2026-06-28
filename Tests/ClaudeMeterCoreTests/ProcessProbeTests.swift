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

    @Test func liveCountsAreAlwaysPositive() {
        // Smoke test: the environment may have zero `claude` processes, so we
        // do NOT assert non-emptiness — only that every reported count is >= 1.
        let counts = LibprocProcessProbe().liveClaudeCwdCounts()
        for (_, count) in counts {
            #expect(count >= 1)
        }
    }
}
