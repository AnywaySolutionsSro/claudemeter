@testable import ClaudeMeterCore
import Foundation
import Testing

struct CodexLimitSourceTests {
    private let base = Date(timeIntervalSince1970: 1_796_000_000)

    private func reading(_ used: Double, at offset: TimeInterval) -> CodexLimitReading {
        CodexLimitReading(
            limitID: "codex", observedAt: base.addingTimeInterval(offset),
            windows: [CodexWindowReading(usedPercent: used, windowMinutes: 300, resetsAt: nil)], reachedType: nil,
        )
    }

    @Test func newestReadingWins() {
        let live = reading(10, at: 60)
        let transcript = reading(20, at: 0)
        #expect(CodexLimitSource.pick(live: live, transcript: transcript) == live)
        let newerTranscript = reading(30, at: 120)
        #expect(CodexLimitSource.pick(live: live, transcript: newerTranscript) == newerTranscript)
    }

    @Test func aTieGoesToLive() {
        let live = reading(10, at: 0)
        #expect(CodexLimitSource.pick(live: live, transcript: reading(20, at: 0)) == live)
    }

    @Test func eitherAloneIsUsed() {
        #expect(CodexLimitSource.pick(live: nil, transcript: reading(1, at: 0))?.windows.first?.usedPercent == 1)
        #expect(CodexLimitSource.pick(live: reading(2, at: 0), transcript: nil)?.windows.first?.usedPercent == 2)
        #expect(CodexLimitSource.pick(live: nil, transcript: nil) == nil)
    }

    @Test func liveIsFreshForTwoMinutes() {
        let live = reading(1, at: 0)
        #expect(CodexLimitSource.isFreshLive(live, shown: live, now: base.addingTimeInterval(119)))
        #expect(!CodexLimitSource.isFreshLive(live, shown: live, now: base.addingTimeInterval(121)))
        // The transcript reading is the one shown: its age matters, so "as of" stays.
        #expect(!CodexLimitSource.isFreshLive(live, shown: reading(1, at: 30), now: base))
        #expect(!CodexLimitSource.isFreshLive(nil, shown: live, now: base))
    }
}
