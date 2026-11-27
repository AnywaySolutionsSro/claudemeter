import Foundation

/// Lenient decoder for the undocumented ChatGPT usage endpoint
/// (`GET https://chatgpt.com/backend-api/wham/usage`), key by key, into the same
/// `CodexLimitReading` transcripts produce.
///
/// Accepts the live shape (`rate_limit.primary_window` / `secondary_window` with
/// `used_percent`, `limit_window_seconds`, `reset_at` / `reset_after_seconds`) and the
/// transcript shape (`primary` / `secondary` with `window_minutes`, `resets_at`), at the
/// top level or under `rate_limits`. A window whose numbers don't parse is dropped, never
/// zeroed; a body with no usable window and no reached flag is no reading at all.
public enum WhamUsageDecoder {
    static let reachedFallback = "limit_reached"

    public static func decode(_ data: Data, observedAt: Date) -> CodexLimitReading? {
        guard let root = LenientJSON.object(data) else { return nil }
        let container = (root["rate_limit"] as? [String: Any]) ?? (root["rate_limits"] as? [String: Any]) ?? root
        let windows = [("primary_window", "primary"), ("secondary_window", "secondary")].compactMap { keys in
            ((container[keys.0] ?? container[keys.1]) as? [String: Any]).flatMap { window($0, observedAt: observedAt) }
        }
        let reached = reachedType(root: root, container: container)
        guard !windows.isEmpty || reached != nil else { return nil }
        return CodexLimitReading(
            limitID: LenientJSON.string(container["limit_id"]) ?? LenientJSON.string(root["limit_id"]) ?? "codex",
            observedAt: observedAt,
            windows: windows,
            reachedType: reached,
            planType: LenientJSON.string(root["plan_type"]) ?? LenientJSON.string(container["plan_type"]),
        )
    }

    /// An explicit `rate_limit_reached_type`, else `"limit_reached"` when the endpoint
    /// says the limit is reached or requests are not allowed.
    private static func reachedType(root: [String: Any], container: [String: Any]) -> String? {
        if let type = LenientJSON.string(container["rate_limit_reached_type"])
            ?? LenientJSON.string(root["rate_limit_reached_type"]) {
            return type
        }
        let limitReached = LenientJSON.bool(container["limit_reached"]) == true
        let notAllowed = LenientJSON.bool(container["allowed"]) == false
        return limitReached || notAllowed ? reachedFallback : nil
    }

    private static func window(_ raw: [String: Any], observedAt: Date) -> CodexWindowReading? {
        guard let used = LenientJSON.double(raw["used_percent"]), let minutes = minutes(raw), minutes > 0 else {
            return nil
        }
        return CodexWindowReading(usedPercent: used, windowMinutes: minutes, resetsAt: resetsAt(raw, observedAt))
    }

    private static func minutes(_ raw: [String: Any]) -> Int? {
        if let minutes = LenientJSON.double(raw["window_minutes"]) { return Int(minutes.rounded()) }
        if let seconds = LenientJSON.double(raw["limit_window_seconds"]) { return Int((seconds / 60).rounded()) }
        return nil
    }

    /// Absolute moments first (`reset_at`, `resets_at` as epoch seconds or ISO-8601),
    /// then `reset_after_seconds` counted from the fetch.
    private static func resetsAt(_ raw: [String: Any], _ observedAt: Date) -> Date? {
        for key in ["reset_at", "resets_at"] {
            if let epoch = LenientJSON.double(raw[key]) { return Date(timeIntervalSince1970: epoch) }
            if let string = LenientJSON.string(raw[key]), let date = ISODate.parse(string) { return date }
        }
        return LenientJSON.double(raw["reset_after_seconds"]).map { observedAt.addingTimeInterval($0) }
    }
}
