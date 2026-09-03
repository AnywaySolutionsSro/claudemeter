import ClaudeMeterCore
import Foundation

/// Fetches organization API spend from `GET /v1/organizations/cost_report`.
///
/// Unlike the subscription endpoint this one is **documented and supported**; polling once a
/// minute is sanctioned, and data lands ~5 minutes after the request it bills for.
/// Refuses redirects: a cross-host 3xx would otherwise carry the `x-api-key` header —
/// which CFNetwork does not strip, unlike `Authorization` — to the redirect target.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession, task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void,
    ) {
        completionHandler(nil)
    }
}

struct CostClient: Sendable {
    private static let base = URL(string: "https://api.anthropic.com/v1/organizations")!
    private static let apiVersion = "2023-06-01"

    /// The API defaults to **7** daily buckets regardless of the date range, silently
    /// truncating a month-long query. Always send a limit; 31 covers the longest month.
    private static let maxDailyBuckets = 31

    /// Total wall-clock budget for a whole paginated fetch, so a stalled request cannot
    /// wedge the store for minutes (each page would otherwise inherit the 60 s default).
    private static let resourceTimeout: TimeInterval = 45

    private let keys: AdminKeyStore
    private let session: URLSession
    private let decoder = CostReportDecoder()

    init(keys: AdminKeyStore = AdminKeyStore(), session: URLSession? = nil) {
        self.keys = keys
        self.session = session ?? Self.makeSession()
    }

    /// Ephemeral so cost figures and credentials never share on-disk cache or cookie
    /// storage with the OAuth traffic.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration,
                          delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// Spend for the current UTC month, following pagination to the end.
    func fetchMonthToDate(now: Date = Date()) async throws -> ApiSpendSnapshot {
        guard let key = keys.load() else { throw CostError.keyUnreadable }

        var accumulator = CostPageAccumulator()
        var cursor: String?
        while true {
            let page = try await requestPage(key: key, now: now, cursor: cursor)
            let next: String?
            do {
                next = try accumulator.accept(page)
            } catch {
                // Duplicate cursor or an exhausted page budget: the total would be wrong.
                throw CostError.unreadableReport
            }
            guard let next else { break }
            cursor = next
        }
        // Any row or bucket we couldn't read means the total is understated. Refuse to
        // report a number rather than show an understated one as fact.
        guard !accumulator.isDegraded else { throw CostError.unreadableReport }
        return accumulator.snapshot(fetchedAt: now)
    }

    /// Confirms the key works and returns the organization's name.
    func verifyOrganization() async throws -> String {
        guard let key = keys.load() else { throw CostError.keyUnreadable }
        let data = try await get(Self.base.appendingPathComponent("me"), key: key)
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = root["name"] as? String
        else {
            throw CostError.network("Malformed response")
        }
        return name
    }

    private func requestPage(
        key: AdminKey, now: Date, cursor: String?,
    ) async throws -> CostReportDecoder.Page {
        let window = CostWindow.trailing(now: now)
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
        // `urlQueryAllowed` leaves `+` unescaped, and a form-decoding server reads it as a
        // space — which corrupts a non-url-safe base64 cursor.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")

        let data = try await get(components.url!, key: key)
        do {
            return try decoder.decode(data)
        } catch {
            throw CostError.unreadableReport
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
            throw CostError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CostError.network("Malformed response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw CostError.invalidAdminKey
            case 403: throw CostError.notAnOrganization
            case 429:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { RetryAfter.seconds($0) }
                throw CostError.rateLimited(retryAfter: retryAfter)
            default: throw CostError.http(http.statusCode)
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
