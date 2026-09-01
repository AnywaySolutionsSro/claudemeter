import ClaudeMeterCore
import Foundation

/// Fetches organization API spend from `GET /v1/organizations/cost_report`.
///
/// Unlike the subscription endpoint this one is **documented and supported**; polling once a
/// minute is sanctioned, and data lands ~5 minutes after the request it bills for.
struct CostClient {
    private static let base = URL(string: "https://api.anthropic.com/v1/organizations")!
    private static let apiVersion = "2023-06-01"

    /// The API defaults to **7** daily buckets regardless of the date range, silently
    /// truncating a month-long query. Always send a limit; 31 covers the longest month.
    private static let maxDailyBuckets = 31

    private let keys: AdminKeyStore
    private let session: URLSession
    private let decoder = CostReportDecoder()

    init(keys: AdminKeyStore = AdminKeyStore(), session: URLSession = .shared) {
        self.keys = keys
        self.session = session
    }

    /// Spend for the current UTC month, following pagination to the end.
    func fetchMonthToDate(now: Date = Date()) async throws -> ApiSpendSnapshot {
        guard let key = keys.load() else { throw UsageError.notAuthenticated }

        var days: [CostDay] = []
        var cursor: String?
        // Bounded so a server that always returns has_more can't spin forever.
        for _ in 0 ..< 12 {
            let page = try await requestPage(key: key, now: now, cursor: cursor)
            days.append(contentsOf: page.days)
            guard let next = page.nextPage else {
                return ApiSpendSnapshot(days: days, fetchedAt: now)
            }
            cursor = next
        }
        return ApiSpendSnapshot(days: days, fetchedAt: now)
    }

    /// Confirms the key works and returns the organization's name.
    func verifyOrganization() async throws -> String {
        guard let key = keys.load() else { throw UsageError.notAuthenticated }
        let data = try await get(Self.base.appendingPathComponent("me"), key: key)
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = root["name"] as? String
        else {
            throw UsageError.network("Malformed response")
        }
        return name
    }

    private func requestPage(
        key: AdminKey, now: Date, cursor: String?,
    ) async throws -> CostReportDecoder.Page {
        let window = CostWindow.monthToDate(now: now)
        var components = URLComponents(
            url: Self.base.appendingPathComponent("cost_report"), resolvingAgainstBaseURL: false,
        )!
        var items = [
            URLQueryItem(name: "starting_at", value: Self.iso(window.start)),
            URLQueryItem(name: "ending_at", value: Self.iso(window.end)),
            URLQueryItem(name: "group_by[]", value: "description"),
            URLQueryItem(name: "limit", value: String(Self.maxDailyBuckets)),
        ]
        if let cursor { items.append(URLQueryItem(name: "page", value: cursor)) }
        components.queryItems = items

        let data = try await get(components.url!, key: key)
        do {
            return try decoder.decode(data)
        } catch {
            throw UsageError.network("Couldn't read the cost report")
        }
    }

    private func get(_ url: URL, key: AdminKey) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(key.raw, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "ClaudeMeter/1.0 (https://github.com/AnywaySolutionsSro/claudemeter)",
            forHTTPHeaderField: "User-Agent",
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network("Malformed response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw UsageError.notAuthenticated
            case 429:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init)
                throw UsageError.rateLimited(retryAfter: retryAfter)
            default: throw UsageError.http(http.statusCode)
            }
        }
        return data
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
