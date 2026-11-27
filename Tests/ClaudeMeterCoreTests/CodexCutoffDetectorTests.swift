@testable import ClaudeMeterCore
import Testing

struct CodexCutoffDetectorTests {
    private let detector = CodexCutoffDetector()

    // swiftlint:disable line_length
    private let started = #"{"timestamp":"t","type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}"#
    private let complete = #"{"timestamp":"t","type":"event_msg","payload":{"type":"task_complete","turn_id":"a"}}"#
    private let userMessage = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}"#
    private let assistant = #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}}"#
    private let toolCall = #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch"}}"#
    private let usageError = #"{"type":"event_msg","payload":{"type":"error","message":"You've hit your usage limit. Try again at 6:20 PM."}}"#
    private let tokenPlain = #"{"type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"rate_limit_reached_type":null}}}"#
    private let tokenReached = #"{"type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"rate_limit_reached_type":"primary"}}}"#
    private let reasoning = #"{"type":"response_item","payload":{"type":"reasoning"}}"#
    // swiftlint:enable line_length

    private func classify(_ lines: [String], running: Bool = false) -> SessionEligibility {
        detector.classify(tailLines: lines, isRunning: running)
    }

    @Test func usageLimitErrorIsCutoff() {
        #expect(classify([started, usageError]) == .eligibleCutoff)
    }

    @Test func usageLimitErrorIsCaseInsensitive() {
        let line = usageError.replacingOccurrences(of: "usage limit", with: "USAGE LIMIT")
        #expect(classify([line]) == .eligibleCutoff)
    }

    @Test func reachedTypeIsCutoff() {
        #expect(classify([started, tokenReached]) == .eligibleCutoff)
    }

    @Test func plainTokenCountIsIgnored() {
        #expect(classify([complete, tokenPlain]) == .cleanlyFinished)
    }

    @Test func taskCompleteIsFinished() {
        #expect(classify([started, assistant, complete]) == .cleanlyFinished)
    }

    @Test func trailingUserMessageAwaits() {
        #expect(classify([complete, userMessage]) == .awaitingUserInput)
    }

    @Test func taskStartedIsRunning() {
        #expect(classify([complete, started]) == .running)
    }

    @Test func assistantMessageAndToolCallAreInFlight() {
        #expect(classify([started, assistant]) == .running)
        #expect(classify([started, toolCall, reasoning]) == .running)
    }

    @Test func errorAfterCutoffRecoveryIsNotStale() {
        // A later task_complete supersedes an earlier cutoff.
        #expect(classify([usageError, started, complete]) == .cleanlyFinished)
    }

    @Test func unrelatedErrorIsNotCutoff() {
        let line = #"{"type":"event_msg","payload":{"type":"error","message":"stream disconnected"}}"#
        #expect(classify([line]) != .eligibleCutoff)
    }

    @Test func runningFlagWinsAndGarbageIsUnknown() {
        #expect(classify([usageError], running: true) == .running)
        #expect(classify(["not json", "{}"]) == .unknown)
        #expect(classify([]) == .unknown)
    }

    @Test func mirroredMessageEventsMentioningLimitAreNotCutoffs() {
        let text = "You've hit your usage limit"
        let agent = #"{"type":"event_msg","payload":{"type":"agent_message","message":""# + text + #""}}"#
        let user = #"{"type":"event_msg","payload":{"type":"user_message","message":""# + text + #""}}"#
        #expect(classify([complete, agent]) == .cleanlyFinished)
        #expect(classify([complete, user]) == .cleanlyFinished)
    }

    @Test func errorTextUnderErrorKeyIsCutoff() {
        let line = #"{"type":"event_msg","payload":{"type":"error","error":"You've hit your usage limit."}}"#
        #expect(classify([started, line]) == .eligibleCutoff)
    }

    @Test func cutoffFollowedByTaskCompleteIsStillCutoff() {
        #expect(classify([started, usageError, tokenReached, complete]) == .eligibleCutoff)
        #expect(classify([usageError, complete]) == .eligibleCutoff)
        let aborted = complete.replacingOccurrences(of: "task_complete", with: "turn_aborted")
        #expect(classify([started, tokenReached, aborted]) == .eligibleCutoff)
    }

    @Test func cutoffInEarlierTurnThenCleanTurnIsFinished() {
        #expect(classify([started, usageError, complete, started, userMessage, assistant, complete]) ==
            .cleanlyFinished)
    }

    @Test func cutoffThenUserMessageAwaits() {
        #expect(classify([started, usageError, complete, userMessage]) == .awaitingUserInput)
    }
}
