import Foundation

/// What one Codex transcript line contributes to a session's state.
enum CodexTranscriptEvent: Equatable {
    /// First line: `session_meta`. `historyMode` is `"legacy"` for threads imported
    /// from Claude Code by Codex Desktop.
    case meta(id: String?, cwd: String?, originator: String?, historyMode: String?)
    /// `turn_context` (or `thread_settings_applied`) naming the model in use.
    case model(String)
    /// `event_msg` / `task_started`: a new turn began.
    case turnStarted
    /// `event_msg` / `token_count`: the session's **cumulative** usage (`nil` when
    /// `info` is null) and the account's limits as of this line.
    case tokenCount(tokens: TokenBreakdown?, limits: CodexLimitReading?)
    /// Any other well-formed entry: counts as activity, nothing else.
    case other
}

/// A parsed line: its timestamp (activity) and what it means.
struct CodexTranscriptLine: Equatable {
    let timestamp: Date?
    let event: CodexTranscriptEvent
}

/// Lenient parser for Codex `rollout-*.jsonl` lines (`{timestamp, type, payload}`).
/// Malformed lines and unknown shapes yield `nil` / `.other`, never a throw: the
/// format is undocumented and changes between Codex releases.
enum CodexTranscriptParser {
    static func parse(_ line: String) -> CodexTranscriptLine? {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let entry = object as? [String: Any]
        else { return nil }
        let timestamp = (entry["timestamp"] as? String).flatMap(ISODate.parse)
        let payload = entry["payload"] as? [String: Any] ?? [:]
        return CodexTranscriptLine(
            timestamp: timestamp,
            event: event(type: entry["type"] as? String, payload: payload, timestamp: timestamp),
        )
    }

    private static func event(type: String?, payload: [String: Any], timestamp: Date?) -> CodexTranscriptEvent {
        switch type {
        case "session_meta":
            .meta(
                id: payload["id"] as? String, cwd: payload["cwd"] as? String,
                originator: payload["originator"] as? String, historyMode: payload["history_mode"] as? String,
            )
        case "turn_context":
            (payload["model"] as? String).map(CodexTranscriptEvent.model) ?? .other
        case "event_msg":
            eventMessage(payload, timestamp: timestamp)
        default:
            .other
        }
    }

    private static func eventMessage(_ payload: [String: Any], timestamp: Date?) -> CodexTranscriptEvent {
        switch payload["type"] as? String {
        case "task_started":
            return .turnStarted
        case "thread_settings_applied":
            let settings = payload["thread_settings"] as? [String: Any]
            return (settings?["model"] as? String).map(CodexTranscriptEvent.model) ?? .other
        case "token_count":
            let info = payload["info"] as? [String: Any]
            return .tokenCount(
                tokens: (info?["total_token_usage"] as? [String: Any]).flatMap(tokens),
                limits: (payload["rate_limits"] as? [String: Any]).flatMap { limits($0, observedAt: timestamp) },
            )
        default:
            return .other
        }
    }

    /// `input_tokens` includes `cached_input_tokens`, so fresh input is the difference;
    /// cached input is a cache read. Codex has no cache-write figure.
    static func tokens(_ usage: [String: Any]) -> TokenBreakdown? {
        guard let input = int(usage["input_tokens"]), let output = int(usage["output_tokens"]) else { return nil }
        let cached = int(usage["cached_input_tokens"]) ?? 0
        return TokenBreakdown(input: max(0, input - cached), output: output, cacheCreation: 0, cacheRead: cached)
    }

    static func limits(_ rateLimits: [String: Any], observedAt: Date?) -> CodexLimitReading? {
        guard let observedAt else { return nil }
        let windows = ["primary", "secondary"].compactMap { key in
            (rateLimits[key] as? [String: Any]).flatMap(window)
        }
        let reached = rateLimits["rate_limit_reached_type"] as? String
        guard !windows.isEmpty || reached != nil else { return nil }
        return CodexLimitReading(
            limitID: rateLimits["limit_id"] as? String ?? "codex",
            observedAt: observedAt,
            windows: windows,
            reachedType: reached,
        )
    }

    private static func window(_ raw: [String: Any]) -> CodexWindowReading? {
        guard let used = double(raw["used_percent"]), let minutes = int(raw["window_minutes"]) else { return nil }
        return CodexWindowReading(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: double(raw["resets_at"]).map(Date.init(timeIntervalSince1970:)),
        )
    }

    private static func int(_ value: Any?) -> Int? {
        number(value)?.intValue
    }

    private static func double(_ value: Any?) -> Double? {
        number(value)?.doubleValue
    }

    /// A JSON number, refusing JSON booleans. `value is Bool` cannot tell them apart:
    /// an `NSNumber` holding 0 or 1 bridges to `Bool`, which would drop `"used_percent": 0`.
    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }
}
