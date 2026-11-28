import Foundation

/// Codex counterpart of `CutoffDetector`: decides from the tail of a Codex
/// rollout whether the session was cut off by the usage limit. Pure and lenient;
/// malformed lines are skipped.
///
/// A cutoff signal in the last turn (since the last `task_started`) that no
/// later user message answered -> `.eligibleCutoff`, even though Codex closes
/// that turn with `task_complete` / `turn_aborted`. Otherwise the last
/// *meaningful* entry decides:
/// - usage-limit error, or `token_count` with a non-null
///   `rate_limits.rate_limit_reached_type` -> `.eligibleCutoff`
/// - `task_complete` / `turn_aborted` -> `.cleanlyFinished`
/// - `task_started`, assistant message, tool call or tool output -> `.running`
/// - user message -> `.awaitingUserInput`
///
/// Ignored (not conversation flow, or duplicates of an entry that is handled):
/// `token_count` without a reached type, `token_usage_record`, `turn_context`,
/// `session_meta`, `world_state`, `compacted`, `configuration_update`,
/// `reasoning`, `agent_message` / `user_message` event mirrors, `item_completed`,
/// `thread_settings_applied`, and `developer`-role messages.
///
/// The usage-limit error shape is unverified; an `event_msg` payload of type
/// `error` or `stream_error` whose `message`, `error` or `text` string contains
/// "usage limit" counts. Other event types (e.g. mirrored `agent_message`) never do.
public struct CodexCutoffDetector: Sendable {
    public init() {}

    public func classify(tailLines: [String], isRunning: Bool) -> SessionEligibility {
        if isRunning { return .running }
        let entries = tailLines.compactMap(entry(for:))
        if lastTurnEndsAtCutoff(entries) { return .eligibleCutoff }
        return entries.last?.verdict ?? .unknown
    }

    /// Codex closes a turn with `task_complete` / `turn_aborted` even when the
    /// limit cut it short, so the last meaningful entry alone would read
    /// `.cleanlyFinished`. The last turn (entries after the last `task_started`,
    /// or the whole tail without one) is a cutoff when it holds a cutoff signal
    /// that no later user message answered.
    private func lastTurnEndsAtCutoff(_ entries: [Entry]) -> Bool {
        let turnStart = entries.lastIndex(where: \.startsTurn).map { $0 + 1 } ?? 0
        let turn = entries[turnStart...]
        guard let cutoff = turn.lastIndex(where: { $0.verdict == .eligibleCutoff }) else { return false }
        return !turn[cutoff...].contains { $0.verdict == .awaitingUserInput }
    }

    /// A meaningful line: the eligibility it implies, and whether it opens a turn.
    private struct Entry {
        let verdict: SessionEligibility
        let startsTurn: Bool
    }

    /// The meaningful entry a single line holds, or `nil` if it is not meaningful.
    private func entry(for line: String) -> Entry? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              let payload = obj["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else { return nil }

        let verdict: SessionEligibility? = switch type {
        case "event_msg": eventVerdict(payloadType, payload)
        case "response_item": itemVerdict(payloadType, payload)
        default: nil
        }
        guard let verdict else { return nil }
        let startsTurn = type == "event_msg" && payloadType == "task_started"
        return Entry(verdict: verdict, startsTurn: startsTurn)
    }

    private func eventVerdict(_ payloadType: String, _ payload: [String: Any]) -> SessionEligibility? {
        switch payloadType {
        case "error", "stream_error":
            // Shape unverified: look for the text under `message`, `error`, then `text`.
            let texts = ["message", "error", "text"].compactMap { payload[$0] as? String }
            return texts.contains { $0.localizedCaseInsensitiveContains("usage limit") } ? .eligibleCutoff : nil
        case "token_count":
            let limits = payload["rate_limits"] as? [String: Any]
            let reached = limits?["rate_limit_reached_type"]
            return (reached == nil || reached is NSNull) ? nil : .eligibleCutoff
        case "task_complete", "turn_aborted": return .cleanlyFinished
        case "task_started": return .running
        default: return nil
        }
    }

    private func itemVerdict(_ payloadType: String, _ payload: [String: Any]) -> SessionEligibility? {
        switch payloadType {
        case "message":
            switch payload["role"] as? String {
            case "user": .awaitingUserInput
            case "assistant": .running
            default: nil
            }
        case "function_call", "custom_tool_call", "function_call_output", "custom_tool_call_output":
            .running
        default: nil
        }
    }
}
