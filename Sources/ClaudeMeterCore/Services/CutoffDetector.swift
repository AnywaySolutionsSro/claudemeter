import Foundation

/// Decides, from the tail of a transcript plus the live running flag, whether a
/// session was cut off mid-task by the usage limit (and is therefore eligible to
/// be nudged with `continue`). Pure and lenient: malformed lines are skipped.
public struct CutoffDetector: Sendable {
    public init() {}

    /// Entry types that are not part of the conversation flow and are ignored
    /// when locating the "last meaningful" entry.
    private static let ignoredTypes: Set<String> = ["ai-title", "mode", "attachment", "summary"]

    public func classify(tailLines: [String], isRunning: Bool) -> SessionEligibility {
        if isRunning { return .running }

        // Find the last meaningful decoded entry.
        for line in tailLines.reversed() {
            guard let entry = decode(line) else { continue }
            if Self.ignoredTypes.contains(entry.type) { continue }

            switch entry.type {
            case "assistant":
                if entry.isApiErrorMessage, entry.model == "<synthetic>",
                   entry.text.localizedCaseInsensitiveContains("limit") {
                    return .eligibleCutoff
                }
                switch entry.stopReason {
                case "end_turn", "stop_sequence": return .cleanlyFinished
                default: return .running // tool_use, max_tokens, nil, etc. => in flight
                }
            case "user":
                // A real user prompt awaits a reply; a [SYSTEM NOTIFICATION ...]
                // entry is automated and does not count as pending user work.
                if entry.text.hasPrefix("[SYSTEM NOTIFICATION") {
                    return .cleanlyFinished
                }
                return .awaitingUserInput
            default:
                continue
            }
        }
        return .unknown
    }

    // MARK: - Minimal lenient decode

    private struct Entry {
        let type: String
        let model: String?
        let stopReason: String?
        let isApiErrorMessage: Bool
        let text: String
    }

    private func decode(_ line: String) -> Entry? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        let message = obj["message"] as? [String: Any]
        return Entry(
            type: type,
            model: message?["model"] as? String,
            stopReason: message?["stop_reason"] as? String,
            isApiErrorMessage: (obj["isApiErrorMessage"] as? Bool) ?? false,
            text: Self.extractText(message?["content"]),
        )
    }

    private static func extractText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let parts = content as? [[String: Any]] else { return "" }
        for part in parts where (part["type"] as? String) == "text" {
            if let t = part["text"] as? String { return t }
        }
        return ""
    }
}
