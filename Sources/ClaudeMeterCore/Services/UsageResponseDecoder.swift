import Foundation

/// Decodes the JSON body of `GET /api/oauth/usage` into a `UsageSnapshot`.
///
/// Uses lenient key-by-key parsing (rather than strict `Codable`) because the endpoint
/// is undocumented and may add buckets/fields over time — unknown keys are ignored and
/// missing buckets simply become `nil`.
public struct UsageResponseDecoder {
    public init() {}

    public enum DecodingError: Error, Equatable { case malformed }

    public func decode(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.malformed
        }

        func bucket(_ key: String) -> UsageBucket? {
            guard
                let object = root[key] as? [String: Any],
                let utilization = (object["utilization"] as? NSNumber)?.doubleValue
            else {
                return nil
            }
            let resetsAt = parseResetsAt(object["resets_at"])
            let status = object["status"] as? String
            return UsageBucket(utilization: utilization, resetsAt: resetsAt, status: status)
        }

        return UsageSnapshot(
            fiveHour: bucket("five_hour"),
            sevenDay: bucket("seven_day"),
            sevenDayOpus: bucket("seven_day_opus"),
            sevenDaySonnet: bucket("seven_day_sonnet"),
            modelWeekly: modelWeeklyLimits(root["limits"]),
            extraUsage: extraUsage(root),
            fetchedAt: fetchedAt,
        )
    }

    /// The paid extra-usage allowance, from whichever of the two overlapping blocks
    /// reads cleanly.
    ///
    /// `spend` wins: it is the newer, structured view (money carries its own currency
    /// and exponent, and it adds the capability flags), the same precedence `limits[]`
    /// has over the legacy `seven_day_<model>` buckets. `extra_usage` is the fallback.
    /// If neither yields a complete amount the result is `nil` — a half-read figure is
    /// no reading at all, never a confident zero.
    private func extraUsage(_ root: [String: Any]) -> ExtraUsage? {
        let legacy = root["extra_usage"] as? [String: Any]
        if let spend = root["spend"] as? [String: Any], let used = Money.parse(spend["used"]) {
            let limit = Money.parse(spend["limit"]) ?? Money.parse((spend["cap"] as? [String: Any])?["money"])
            return ExtraUsage(
                // A `spend` block that stopped reporting `enabled` still carries real
                // numbers; the legacy flag answers it, and "on" is the safer guess.
                isEnabled: (spend["enabled"] as? Bool) ?? (legacy?["is_enabled"] as? Bool) ?? true,
                used: used,
                limit: limit,
                utilization: (spend["percent"] as? NSNumber)?.doubleValue,
                capReached: (legacy?["spend_limit_reached"] as? Bool) ?? false,
                disabledReason: reason(spend["disabled_reason"]) ?? reason(legacy?["disabled_reason"]),
                canPurchase: (spend["can_purchase_credits"] as? Bool) ?? false,
            )
        }
        return legacyExtraUsage(legacy)
    }

    /// The older `extra_usage` block, which spreads one amount across three fields
    /// (`used_credits`, `currency`, `decimal_places`).
    private func legacyExtraUsage(_ block: [String: Any]?) -> ExtraUsage? {
        guard
            let block,
            let used = Money(
                minorUnits: block["used_credits"], currency: block["currency"],
                exponent: block["decimal_places"],
            )
        else {
            return nil
        }
        return ExtraUsage(
            isEnabled: (block["is_enabled"] as? Bool) ?? false,
            used: used,
            limit: Money(
                minorUnits: block["monthly_limit"], currency: block["currency"],
                exponent: block["decimal_places"],
            ),
            utilization: (block["utilization"] as? NSNumber)?.doubleValue,
            capReached: (block["spend_limit_reached"] as? Bool) ?? false,
            disabledReason: reason(block["disabled_reason"]),
        )
    }

    /// A non-empty reason string, treating JSON `null` and `""` alike as "no reason".
    private func reason(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Per-model weekly windows from the `limits[]` array: entries with
    /// `kind == "weekly_scoped"`, a numeric `percent` and a
    /// `scope.model.display_name`. Anything else (session, weekly_all, junk) is
    /// skipped — the array is undocumented and may grow.
    private func modelWeeklyLimits(_ value: Any?) -> [ModelWeeklyLimit] {
        guard let entries = value as? [Any] else { return [] }
        return entries.compactMap { entry -> ModelWeeklyLimit? in
            guard
                let object = entry as? [String: Any],
                object["kind"] as? String == "weekly_scoped",
                let percent = (object["percent"] as? NSNumber)?.doubleValue,
                let scope = object["scope"] as? [String: Any],
                let model = scope["model"] as? [String: Any],
                let name = model["display_name"] as? String, !name.isEmpty
            else {
                return nil
            }
            // A surface-scoped window ("Fable · Cowork") must not collide with the
            // model-wide one: the label doubles as the row/gauge identity.
            let surface = (scope["surface"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let label = surface.map { "\(name) · \($0)" } ?? name
            let bucket = UsageBucket(
                utilization: percent,
                resetsAt: parseResetsAt(object["resets_at"]),
                // `severity` ("normal", …) — a different vocabulary from the top-level
                // buckets' `status`; nothing reads `status` today, kept for diagnostics.
                status: object["severity"] as? String,
            )
            return ModelWeeklyLimit(
                label: label,
                bucket: bucket,
                isActive: (object["is_active"] as? Bool) ?? false,
            )
        }
    }

    /// `resets_at` is an ISO-8601 string in the live API, but the CLI's own docs describe it
    /// as epoch seconds — accept either form defensively.
    private func parseResetsAt(_ value: Any?) -> Date? {
        if let string = value as? String {
            return ISODate.parse(string)
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        return nil
    }
}
