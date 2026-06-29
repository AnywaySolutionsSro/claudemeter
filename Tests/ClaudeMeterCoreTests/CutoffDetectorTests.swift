import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct CutoffDetectorTests {
    private let detector = CutoffDetector()

    private let cutoffLine = #"{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"You've hit your session limit · resets 4:30am (Europe/Bratislava)"}]}}"#
    private let cleanLine = #"{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"All done — tests pass."}]}}"#
    private let toolUseLine = #"{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}]}}"#
    private let userLine = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"please refactor this"}]}}"#
    private let systemNotifLine = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[SYSTEM NOTIFICATION - NOT USER INPUT] background event"}]}}"#
    private let aiTitleLine = #"{"type":"ai-title"}"#
    private let modeLine = #"{"type":"mode"}"#

    @Test func cutoffWhenTailIsSyntheticLimit() {
        #expect(detector.classify(tailLines: [cleanLine, userLine, cutoffLine], isRunning: false) == .eligibleCutoff)
    }

    @Test func ignoresTrailingNonConversationalEntries() {
        #expect(detector.classify(tailLines: [cutoffLine, aiTitleLine, modeLine], isRunning: false) == .eligibleCutoff)
    }

    @Test func cleanFinishIsNotEligible() {
        #expect(detector.classify(tailLines: [userLine, cleanLine], isRunning: false) == .cleanlyFinished)
    }

    @Test func toolUseTailMeansRunning() {
        #expect(detector.classify(tailLines: [userLine, toolUseLine], isRunning: false) == .running)
    }

    @Test func isRunningOverridesCutoff() {
        #expect(detector.classify(tailLines: [cutoffLine], isRunning: true) == .running)
    }

    @Test func realUserPromptAwaitsInput() {
        #expect(detector.classify(tailLines: [cleanLine, userLine], isRunning: false) == .awaitingUserInput)
    }

    @Test func systemNotificationUserIsNotAwaitingInput() {
        // A [SYSTEM NOTIFICATION ...] user entry is not a real prompt.
        #expect(detector.classify(tailLines: [cleanLine, systemNotifLine], isRunning: false) == .cleanlyFinished)
    }

    @Test func emptyTailIsUnknown() {
        #expect(detector.classify(tailLines: [], isRunning: false) == .unknown)
    }
}
