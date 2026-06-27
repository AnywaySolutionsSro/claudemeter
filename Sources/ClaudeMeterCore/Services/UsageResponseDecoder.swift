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
            fetchedAt: fetchedAt
        )
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
