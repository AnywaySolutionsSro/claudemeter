import Foundation

/// Codex counterpart of `CutoffDetector`: decides from the tail of a Codex
/// rollout whether the session was cut off by the usage limit. Pure and lenient;
/// malformed lines are skipped.
///
/// The last *meaningful* entry decides:
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
/// The usage-limit error shape is unverified; any `event_msg` payload of type
/// `error` (or carrying a `message` string) containing "usage limit" counts.
public struct CodexCutoffDetector: Sendable {
    public init() {}

    public func classify(tailLines: [String], isRunning: Bool) -> SessionEligibility {
        if isRunning { return .running }
        for line in tailLines.reversed() {
            if let verdict = verdict(for: line) { return verdict }
        }
        return .unknown
    }

    /// The eligibility a single line implies, or `nil` if it is not meaningful.
    private func verdict(for line: String) -> SessionEligibility? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              let payload = obj["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else { return nil }

        switch type {
        case "event_msg": return eventVerdict(payloadType, payload)
        case "response_item": return itemVerdict(payloadType, payload)
        default: return nil
        }
    }

    private func eventVerdict(_ payloadType: String, _ payload: [String: Any]) -> SessionEligibility? {
        if let message = payload["message"] as? String,
           message.localizedCaseInsensitiveContains("usage limit") {
            return .eligibleCutoff
        }
        switch payloadType {
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
