# API Spend Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the Claude API organization's USD spend (today, month to date, per model) in ClaudeMeter's dropdown, in Settings, and in a new widget.

**Architecture:** A new `CostReportDecoder` in `ClaudeMeterCore` leniently parses `GET /v1/organizations/cost_report` into an `ApiSpendSnapshot`; the app layer adds a Keychain-backed `AdminKeyStore`, a paginating `CostClient`, and an `ApiSpendStore` view-model that publishes to the dropdown and delivers a JSON file into the widget's own sandbox container. Mirrors the existing `UsageResponseDecoder` / `UsageClient` / `UsageStore` / `SnapshotStore` quartet exactly.

**Tech Stack:** Swift 6, SwiftPM + XcodeGen, SwiftUI, AppKit, WidgetKit, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-30-api-spend-tracking-design.md`

## Global Constraints

- **`amount` from the API is a decimal string in CENTS.** `"103.1554"` means **$1.03**. Divide by 100 exactly once, inside `CostReportDecoder`. Never `Double` for money — use `Decimal`.
- **Always send `limit` explicitly** on `cost_report`; it defaults to 7 daily buckets regardless of date range and silently truncates. Follow `has_more` / `next_page`.
- Input and output arrive as **separate rows within one day** (split by `token_type`) and must be summed.
- Buckets are **UTC-aligned**; present UTC days so figures match the invoice.
- New testable logic goes in **`ClaudeMeterCore`** with tests in `Tests/ClaudeMeterCoreTests`. Core line coverage must stay **≥ 80%** (`scripts/coverage-gate.sh`).
- Zero compiler warnings (`-warnings-as-errors`), `swiftlint --strict`, `swiftformat --lint` all pass. Run `swiftformat . && swiftlint --strict && scripts/coverage-gate.sh` before pushing.
- No `print()`. Files < 400 lines. Prefer `let`, value types, immutability.
- **Fixtures are synthetic** — the repo is public; real org spend figures stay out of it.
- Admin key: never logged, never rendered back, never sent anywhere but `api.anthropic.com`.
- Branch `feat/api-spend-tracking`; PR title must be a Conventional Commit subject; PR body needs a `## Release notes` section.

---

### Task 1: `AdminKey` value type

**Files:**
- Create: `Sources/ClaudeMeterCore/Models/AdminKey.swift`
- Test: `Tests/ClaudeMeterCoreTests/AdminKeyTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `AdminKey` — `init?(_ raw: String)`, `var raw: String`, `static let prefix = "sk-ant-admin01-"`

- [ ] **Step 1: Write the failing test**

```swift
@testable import ClaudeMeterCore
import XCTest

final class AdminKeyTests: XCTestCase {
    func testAcceptsAWellFormedKey() {
        let key = AdminKey("sk-ant-admin01-abc123")
        XCTAssertEqual(key?.raw, "sk-ant-admin01-abc123")
    }

    func testTrimsSurroundingWhitespaceFromAPaste() {
        XCTAssertEqual(AdminKey("  sk-ant-admin01-abc123\n")?.raw, "sk-ant-admin01-abc123")
    }

    func testRejectsTheWrongPrefix() {
        // A regular API key, not an admin key — the endpoint would 401 confusingly.
        XCTAssertNil(AdminKey("sk-ant-api01-abc123"))
    }

    func testRejectsThePrefixAlone() {
        XCTAssertNil(AdminKey("sk-ant-admin01-"))
    }

    func testRejectsEmptyInput() {
        XCTAssertNil(AdminKey(""))
        XCTAssertNil(AdminKey("   "))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AdminKeyTests`
Expected: FAIL — `cannot find 'AdminKey' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// A Claude Console **Admin API key** (`sk-ant-admin01-…`).
///
/// Validating the prefix at entry turns a mis-paste into an immediate, clear rejection in
/// Settings instead of a confusing HTTP 401 later.
public struct AdminKey: Equatable, Sendable {
    public static let prefix = "sk-ant-admin01-"

    public let raw: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix), trimmed.count > Self.prefix.count else { return nil }
        self.raw = trimmed
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AdminKeyTests`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeMeterCore/Models/AdminKey.swift Tests/ClaudeMeterCoreTests/AdminKeyTests.swift
git commit -m "feat(core): add AdminKey with prefix validation"
```

---

### Task 2: Spend models + currency formatting

**Files:**
- Create: `Sources/ClaudeMeterCore/Models/ApiSpendSnapshot.swift`
- Modify: `Sources/ClaudeMeterCore/Formatting.swift` (append `usd`)
- Test: `Tests/ClaudeMeterCoreTests/ApiSpendSnapshotTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `ModelSpend` — `let model: String`, `let amountUSD: Decimal`
  - `CostDay` — `let start: Date`, `let amountUSD: Decimal`, `let byModel: [ModelSpend]`
  - `ApiSpendSnapshot` — `init(days: [CostDay], fetchedAt: Date)`, `var totalUSD: Decimal`, `func todayUSD(now: Date) -> Decimal`, `var byModel: [ModelSpend]`, `var isEmpty: Bool`, `let fetchedAt: Date`. All `Codable, Equatable, Sendable`.
  - `Formatting.usd(_ amount: Decimal) -> String`

- [ ] **Step 1: Write the failing test**

```swift
@testable import ClaudeMeterCore
import XCTest

final class ApiSpendSnapshotTests: XCTestCase {
    /// 2026-08-21T00:00:00Z and the two days after it.
    private func utcDay(_ day: Int) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = day
        components.hour = 0; components.minute = 0; components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func snapshot() -> ApiSpendSnapshot {
        ApiSpendSnapshot(
            days: [
                CostDay(start: utcDay(21), amountUSD: Decimal(string: "1.3691")!,
                        byModel: [ModelSpend(model: "claude-sonnet-5", amountUSD: Decimal(string: "1.3691")!)]),
                CostDay(start: utcDay(22), amountUSD: Decimal(string: "1.2186")!,
                        byModel: [ModelSpend(model: "claude-sonnet-5", amountUSD: Decimal(string: "1.2186")!),
                                  ModelSpend(model: "claude-opus-5", amountUSD: Decimal(string: "0.5000")!)]),
            ],
            fetchedAt: utcDay(23),
        )
    }

    func testTotalSumsEveryDay() {
        XCTAssertEqual(snapshot().totalUSD, Decimal(string: "2.5877")!)
    }

    func testTodayMatchesTheUTCDayContainingNow() {
        // 23:30 UTC on the 22nd still belongs to the 22nd's bucket.
        let late = utcDay(22).addingTimeInterval(23 * 3600 + 1800)
        XCTAssertEqual(snapshot().todayUSD(now: late), Decimal(string: "1.2186")!)
    }

    func testTodayIsZeroWhenNoBucketExistsYet() {
        XCTAssertEqual(snapshot().todayUSD(now: utcDay(25)), 0)
    }

    func testByModelAggregatesAcrossDaysDescending() {
        let models = snapshot().byModel
        XCTAssertEqual(models.map(\.model), ["claude-sonnet-5", "claude-opus-5"])
        XCTAssertEqual(models[0].amountUSD, Decimal(string: "2.5877")!)
        XCTAssertEqual(models[1].amountUSD, Decimal(string: "0.5000")!)
    }

    func testIsEmptyWhenNoDaysCarrySpend() {
        let empty = ApiSpendSnapshot(days: [], fetchedAt: utcDay(23))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(snapshot().isEmpty)
    }

    func testRoundTripsThroughCodableForTheWidget() throws {
        let data = try JSONEncoder().encode(snapshot())
        XCTAssertEqual(try JSONDecoder().decode(ApiSpendSnapshot.self, from: data), snapshot())
    }

    func testFormatsSmallAmountsToCents() {
        XCTAssertEqual(Formatting.usd(Decimal(string: "2.5877")!), "$2.59")
        XCTAssertEqual(Formatting.usd(0), "$0.00")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ApiSpendSnapshotTests`
Expected: FAIL — `cannot find 'ApiSpendSnapshot' in scope`

- [ ] **Step 3: Write minimal implementation**

Create `Sources/ClaudeMeterCore/Models/ApiSpendSnapshot.swift`:

```swift
import Foundation

/// Spend attributed to one model within a day (or aggregated across days).
public struct ModelSpend: Codable, Equatable, Sendable {
    public let model: String
    public let amountUSD: Decimal

    public init(model: String, amountUSD: Decimal) {
        self.model = model
        self.amountUSD = amountUSD
    }
}

/// One UTC-aligned day of API spend.
///
/// `start` is the bucket's `starting_at`. Buckets are UTC-aligned, so a local day straddles
/// two of them; we present UTC days deliberately, so the figures agree with the invoice.
public struct CostDay: Codable, Equatable, Sendable {
    public let start: Date
    public let amountUSD: Decimal
    public let byModel: [ModelSpend]

    public init(start: Date, amountUSD: Decimal, byModel: [ModelSpend]) {
        self.start = start
        self.amountUSD = amountUSD
        self.byModel = byModel
    }
}

/// A window of API spend, as fetched from the Cost API. `Codable` so the app can hand it
/// to the widget extension as JSON.
public struct ApiSpendSnapshot: Codable, Equatable, Sendable {
    public let days: [CostDay]
    public let fetchedAt: Date

    public init(days: [CostDay], fetchedAt: Date) {
        self.days = days
        self.fetchedAt = fetchedAt
    }

    /// Total across the whole fetched window. The store requests exactly month-to-date,
    /// so this is what the UI labels "Month to date".
    public var totalUSD: Decimal { days.reduce(0) { $0 + $1.amountUSD } }

    public var isEmpty: Bool { totalUSD == 0 }

    /// Spend in the UTC day containing `now`; zero when that bucket hasn't appeared yet.
    public func todayUSD(now: Date) -> Decimal {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return days
            .first { calendar.isDate($0.start, inSameDayAs: now) }?
            .amountUSD ?? 0
    }

    /// Per-model totals across every day, most expensive first.
    public var byModel: [ModelSpend] {
        var totals: [String: Decimal] = [:]
        for day in days {
            for entry in day.byModel {
                totals[entry.model, default: 0] += entry.amountUSD
            }
        }
        return totals
            .map { ModelSpend(model: $0.key, amountUSD: $0.value) }
            .sorted(by: Self.mostExpensiveFirst)
    }

    /// Descending by amount, then alphabetical so equal amounts have a stable order.
    static func mostExpensiveFirst(_ lhs: ModelSpend, _ rhs: ModelSpend) -> Bool {
        lhs.amountUSD == rhs.amountUSD ? lhs.model < rhs.model : lhs.amountUSD > rhs.amountUSD
    }
}
```

Append to `Sources/ClaudeMeterCore/Formatting.swift`, inside `enum Formatting`:

```swift
    /// Formats USD for display, always to cents (`$2.59`).
    public static func usd(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ApiSpendSnapshotTests`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeMeterCore/Models/ApiSpendSnapshot.swift Sources/ClaudeMeterCore/Formatting.swift Tests/ClaudeMeterCoreTests/ApiSpendSnapshotTests.swift
git commit -m "feat(core): add ApiSpendSnapshot models and USD formatting"
```

---

### Task 3: `CostReportDecoder` — the cents conversion

**Files:**
- Create: `Sources/ClaudeMeterCore/Services/CostReportDecoder.swift`
- Test: `Tests/ClaudeMeterCoreTests/CostReportDecoderTests.swift`

**Interfaces:**
- Consumes: `CostDay`, `ModelSpend` (Task 2)
- Produces: `CostReportDecoder` — `init()`, `enum DecodingError: Error, Equatable { case malformed }`, `struct Page: Equatable, Sendable { let days: [CostDay]; let nextPage: String? }`, `func decode(_ data: Data) throws -> Page`

This is the task the whole feature hinges on. **`amount` is in cents.**

- [ ] **Step 1: Write the failing test**

```swift
@testable import ClaudeMeterCore
import XCTest

final class CostReportDecoderTests: XCTestCase {
    private let decoder = CostReportDecoder()

    /// The verified shape of `GET /v1/organizations/cost_report`, synthetic values.
    /// One day, split into the separate input/output rows the API really returns.
    private let realShape = Data("""
    {"data":[
      {"starting_at":"2026-08-21T00:00:00Z","ending_at":"2026-08-22T00:00:00Z","results":[
        {"currency":"USD","amount":"103.1554","workspace_id":null,
         "description":"Claude Sonnet 5 - Input Tokens","cost_type":"tokens",
         "context_window":"0-200k","model":"claude-sonnet-5","service_tier":"standard",
         "token_type":"uncached_input_tokens","inference_geo":"global"},
        {"currency":"USD","amount":"33.755","workspace_id":null,
         "description":"Claude Sonnet 5 - Output Tokens","cost_type":"tokens",
         "context_window":"0-200k","model":"claude-sonnet-5","service_tier":"standard",
         "token_type":"output_tokens","inference_geo":"global"}
      ]},
      {"starting_at":"2026-08-22T00:00:00Z","ending_at":"2026-08-23T00:00:00Z","results":[]}
    ],"has_more":false,"next_page":null}
    """.utf8)

    // THE bug this decoder exists to prevent: `amount` is a decimal string in CENTS.
    // "103.1554" + "33.755" = 136.9104 cents = $1.3691, NOT $136.91.
    func testConvertsCentsToDollars() throws {
        let page = try decoder.decode(realShape)
        XCTAssertEqual(page.days[0].amountUSD, Decimal(string: "1.369104")!)
    }

    func testSumsTheSeparateInputAndOutputRowsOfOneDay() throws {
        let page = try decoder.decode(realShape)
        XCTAssertEqual(page.days[0].byModel.count, 1)
        XCTAssertEqual(page.days[0].byModel[0].model, "claude-sonnet-5")
        XCTAssertEqual(page.days[0].byModel[0].amountUSD, Decimal(string: "1.369104")!)
    }

    func testParsesTheBucketStartAsUTC() throws {
        let page = try decoder.decode(realShape)
        XCTAssertEqual(page.days[0].start, Date(timeIntervalSince1970: 1_787_270_400))
    }

    func testKeepsDaysWithEmptyResultsAsZero() throws {
        let page = try decoder.decode(realShape)
        XCTAssertEqual(page.days.count, 2)
        XCTAssertEqual(page.days[1].amountUSD, 0)
        XCTAssertTrue(page.days[1].byModel.isEmpty)
    }

    func testReportsNoNextPageWhenHasMoreIsFalse() throws {
        XCTAssertNil(try decoder.decode(realShape).nextPage)
    }

    func testReportsTheNextPageCursorWhenHasMoreIsTrue() throws {
        let paged = Data("""
        {"data":[],"has_more":true,"next_page":"page_abc123"}
        """.utf8)
        XCTAssertEqual(try decoder.decode(paged).nextPage, "page_abc123")
    }

    func testIgnoresACursorWhenHasMoreIsFalse() throws {
        let stale = Data("""
        {"data":[],"has_more":false,"next_page":"page_abc123"}
        """.utf8)
        XCTAssertNil(try decoder.decode(stale).nextPage)
    }

    func testGroupsRowsByModelWithinADay() throws {
        let mixed = Data("""
        {"data":[{"starting_at":"2026-08-21T00:00:00Z","ending_at":"2026-08-22T00:00:00Z","results":[
          {"currency":"USD","amount":"100","model":"claude-sonnet-5","token_type":"output_tokens"},
          {"currency":"USD","amount":"300","model":"claude-opus-5","token_type":"output_tokens"}
        ]}],"has_more":false,"next_page":null}
        """.utf8)
        let day = try decoder.decode(mixed).days[0]
        XCTAssertEqual(day.amountUSD, 4)
        XCTAssertEqual(day.byModel.map(\.model), ["claude-opus-5", "claude-sonnet-5"])
        XCTAssertEqual(day.byModel[0].amountUSD, 3)
    }

    // Lenient parsing: the endpoint will grow fields, and rows without a model
    // (e.g. Code Execution Usage) still count toward the day's total.
    func testFallsBackToDescriptionWhenModelIsAbsent() throws {
        let noModel = Data("""
        {"data":[{"starting_at":"2026-08-21T00:00:00Z","ending_at":"2026-08-22T00:00:00Z","results":[
          {"currency":"USD","amount":"250","description":"Code Execution Usage","brand_new_key":1}
        ]}],"has_more":false,"next_page":null}
        """.utf8)
        let day = try decoder.decode(noModel).days[0]
        XCTAssertEqual(day.amountUSD, Decimal(string: "2.5")!)
        XCTAssertEqual(day.byModel.map(\.model), ["Code Execution Usage"])
    }

    func testSkipsRowsWithAnUnparseableAmount() throws {
        let junk = Data("""
        {"data":[{"starting_at":"2026-08-21T00:00:00Z","ending_at":"2026-08-22T00:00:00Z","results":[
          {"currency":"USD","amount":"not-a-number","model":"claude-sonnet-5"},
          {"currency":"USD","amount":"100","model":"claude-sonnet-5"}
        ]}],"has_more":false,"next_page":null}
        """.utf8)
        XCTAssertEqual(try decoder.decode(junk).days[0].amountUSD, 1)
    }

    func testSkipsBucketsWithAnUnparseableStart() throws {
        let junk = Data("""
        {"data":[{"starting_at":"tomorrow","results":[]}],"has_more":false,"next_page":null}
        """.utf8)
        XCTAssertTrue(try decoder.decode(junk).days.isEmpty)
    }

    func testThrowsOnNonObjectRoot() {
        XCTAssertThrowsError(try decoder.decode(Data("[]".utf8))) { error in
            XCTAssertEqual(error as? CostReportDecoder.DecodingError, .malformed)
        }
    }

    func testTreatsAMissingDataArrayAsNoDays() throws {
        XCTAssertTrue(try decoder.decode(Data("{}".utf8)).days.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CostReportDecoderTests`
Expected: FAIL — `cannot find 'CostReportDecoder' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Decodes `GET /v1/organizations/cost_report` into `CostDay` values.
///
/// Lenient key-by-key parsing (like `UsageResponseDecoder`): unknown keys are ignored and
/// unparseable rows are skipped rather than failing the whole fetch.
///
/// **The `amount` field is a decimal string in CENTS, not dollars.** `"103.1554"` is $1.03.
/// Reading it as dollars overstates spend 100×. The division lives here and nowhere else.
public struct CostReportDecoder {
    public init() {}

    public enum DecodingError: Error, Equatable { case malformed }

    /// One page of the paginated report.
    public struct Page: Equatable, Sendable {
        public let days: [CostDay]
        /// Cursor for the next page, or `nil` when `has_more` is false.
        public let nextPage: String?
    }

    private static let centsPerDollar = Decimal(100)

    public func decode(_ data: Data) throws -> Page {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.malformed
        }

        let buckets = root["data"] as? [[String: Any]] ?? []
        let days = buckets.compactMap(day(from:))

        let hasMore = (root["has_more"] as? NSNumber)?.boolValue ?? false
        let nextPage = hasMore ? root["next_page"] as? String : nil

        return Page(days: days, nextPage: nextPage)
    }

    private func day(from bucket: [String: Any]) -> CostDay? {
        guard
            let startString = bucket["starting_at"] as? String,
            let start = ISODate.parse(startString)
        else {
            return nil
        }

        // Input and output arrive as separate rows for the same model; fold them together.
        var totals: [String: Decimal] = [:]
        var order: [String] = []
        for row in bucket["results"] as? [[String: Any]] ?? [] {
            guard
                let amountString = row["amount"] as? String,
                let cents = Decimal(string: amountString)
            else {
                continue
            }
            // Rows without a model (e.g. "Code Execution Usage") still count toward the day.
            let label = row["model"] as? String ?? row["description"] as? String ?? "Other"
            if totals[label] == nil { order.append(label) }
            totals[label, default: 0] += cents / Self.centsPerDollar
        }

        let byModel = order
            .map { ModelSpend(model: $0, amountUSD: totals[$0] ?? 0) }
            .sorted(by: ApiSpendSnapshot.mostExpensiveFirst)

        return CostDay(
            start: start,
            amountUSD: byModel.reduce(0) { $0 + $1.amountUSD },
            byModel: byModel,
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CostReportDecoderTests`
Expected: PASS (13 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeMeterCore/Services/CostReportDecoder.swift Tests/ClaudeMeterCoreTests/CostReportDecoderTests.swift
git commit -m "feat(core): decode cost_report, converting cents to dollars"
```

---

### Task 4: `AdminKeyStore` — Keychain persistence

**Files:**
- Create: `Sources/ClaudeMeter/Support/AdminKeyStore.swift`

**Interfaces:**
- Consumes: `AdminKey` (Task 1), existing `Keychain` struct (`Sources/ClaudeMeter/Support/Keychain.swift`)
- Produces: `AdminKeyStore` — `static let service = "com.jakubzak.claudemeter.adminkey"`, `init()`, `var hasKey: Bool`, `func load() -> AdminKey?`, `func save(_ key: AdminKey) throws`, `func clear()`

No unit test: this is a thin Keychain wrapper in the app target (which has no test target), exactly like the existing `AccountStore`. Its correctness is exercised by the Settings Verify button in Task 8.

- [ ] **Step 1: Write the implementation**

```swift
import ClaudeMeterCore
import Foundation

/// Owns the Claude Console **Admin API key** in ClaudeMeter's own Keychain item.
///
/// Mirrors `AccountStore`: because the app creates the item, it reads it back without
/// prompting. The key is never returned to a view — callers ask `hasKey` to decide what to
/// render, and only `CostClient` ever reads the value.
struct AdminKeyStore {
    static let service = "com.jakubzak.claudemeter.adminkey"
    static let account = "default"

    private let keychain = Keychain(service: service)

    var hasKey: Bool { load() != nil }

    func load() -> AdminKey? {
        guard
            let item = try? keychain.read(),
            let raw = String(data: item.data, encoding: .utf8)
        else {
            return nil
        }
        return AdminKey(raw)
    }

    func save(_ key: AdminKey) throws {
        try keychain.write(Data(key.raw.utf8), account: Self.account)
    }

    func clear() {
        try? keychain.delete(account: Self.account)
    }
}
```

- [ ] **Step 2: Verify it compiles with no warnings**

Run: `swift build -c release 2>&1 | tail -5`
Expected: no errors, no warnings (the SPM build includes the app target)

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeMeter/Support/AdminKeyStore.swift
git commit -m "feat: store the admin API key in ClaudeMeter's own Keychain item"
```

---

### Task 5: `CostClient` — networking with pagination

**Files:**
- Create: `Sources/ClaudeMeter/Support/CostClient.swift`

**Interfaces:**
- Consumes: `AdminKey`, `ApiSpendSnapshot`, `CostReportDecoder` (Tasks 1–3); `AdminKeyStore` (Task 4); existing `UsageError`
- Produces: `CostClient` — `init(keys: AdminKeyStore = AdminKeyStore(), session: URLSession = .shared)`, `func fetchMonthToDate(now: Date) async throws -> ApiSpendSnapshot`, `func verifyOrganization() async throws -> String`

`verifyOrganization()` calls `/v1/organizations/me` and returns the org name — that is what the Settings Verify button shows.

- [ ] **Step 1: Write the implementation**

```swift
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
        var components = URLComponents(
            url: Self.base.appendingPathComponent("cost_report"), resolvingAgainstBaseURL: false,
        )!
        var items = [
            URLQueryItem(name: "starting_at", value: Self.iso(Self.startOfUTCMonth(now))),
            URLQueryItem(name: "ending_at", value: Self.iso(Self.startOfNextUTCDay(now))),
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
        request.setValue("ClaudeMeter/1.0 (https://github.com/AnywaySolutionsSro/claudemeter)",
                         forHTTPHeaderField: "User-Agent")

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
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
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

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private static func startOfUTCMonth(_ now: Date) -> Date {
        let components = utcCalendar.dateComponents([.year, .month], from: now)
        return utcCalendar.date(from: components) ?? now
    }

    /// Exclusive upper bound: the API's `ending_at` must pass the end of today's bucket
    /// for today's partial spend to be included.
    private static func startOfNextUTCDay(_ now: Date) -> Date {
        let startOfToday = utcCalendar.startOfDay(for: now)
        return utcCalendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
    }
}
```

- [ ] **Step 2: Verify it compiles with no warnings**

Run: `swift build -c release 2>&1 | tail -5`
Expected: no errors, no warnings

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeMeter/Support/CostClient.swift
git commit -m "feat: fetch month-to-date API spend with explicit paging"
```

---

### Task 6: `ApiSpendStore` — view-model, cache, widget delivery

**Files:**
- Create: `Sources/ClaudeMeter/App/ApiSpendStore.swift`

**Interfaces:**
- Consumes: `CostClient` (Task 5), `AdminKeyStore` (Task 4), `ApiSpendSnapshot` (Task 2)
- Produces: `ApiSpendStore` — `@MainActor final class ApiSpendStore: ObservableObject`, `@Published var snapshot: ApiSpendSnapshot?`, `@Published var errorMessage: String?`, `@Published var isLoading: Bool`, `var hasKey: Bool`, `func refresh(force: Bool) async`, `func start()`, `static func widgetInboxURL() -> URL`

Cadence: on dropdown-open, throttled to ≥5 minutes, plus a 15-minute background tick. Cost data is daily-granularity and lands ~5 minutes behind, so 30 s polling would burn requests for nothing.

- [ ] **Step 1: Write the implementation**

```swift
import ClaudeMeterCore
import Combine
import Foundation
import OSLog
import WidgetKit

/// Publishes organization API spend to the dropdown and delivers it to the widget.
///
/// Mirrors `UsageStore`, but polls far less often: the Cost API is daily-granularity and
/// trails real usage by ~5 minutes, so anything faster is wasted traffic.
@MainActor
final class ApiSpendStore: ObservableObject {
    private static let log = Logger(subsystem: "com.jakubzak.claudemeter", category: "apispend")

    /// Minimum gap between fetches triggered by opening the dropdown.
    private static let throttle: TimeInterval = 5 * 60
    /// Background refresh cadence.
    private static let tick: TimeInterval = 15 * 60

    @Published private(set) var snapshot: ApiSpendSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    private let client: CostClient
    private let keys: AdminKeyStore
    private var lastFetch: Date?
    private var timer: Timer?

    init(client: CostClient = CostClient(), keys: AdminKeyStore = AdminKeyStore()) {
        self.client = client
        self.keys = keys
        snapshot = Self.readCache()
    }

    var hasKey: Bool { keys.hasKey }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(force: true) }
        }
        Task { await refresh(force: true) }
    }

    func refresh(force: Bool = false) async {
        guard hasKey else {
            snapshot = nil
            errorMessage = nil
            return
        }
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < Self.throttle { return }
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let fresh = try await client.fetchMonthToDate(now: Date())
            lastFetch = Date()
            snapshot = fresh
            errorMessage = nil
            Self.writeCache(fresh)
            deliverToWidget(fresh)
        } catch {
            // Keep showing the cached snapshot; surface why it's stale.
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Self.log.notice("api spend refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Forget everything when the key is removed, so no stale figures linger.
    func reset() {
        snapshot = nil
        errorMessage = nil
        lastFetch = nil
        try? FileManager.default.removeItem(at: Self.cacheURL)
        try? FileManager.default.removeItem(at: Self.widgetInboxURL())
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Widget delivery

    /// A sandboxed widget cannot read the non-sandboxed app's App Group container, so the
    /// snapshot is written into the widget's **own** container — the same trick
    /// `SessionMonitor` uses. Kept as a separate file from `snapshot.json` because the two
    /// producers run on different cadences and would otherwise race.
    nonisolated static func widgetInboxURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Containers/com.jakubzak.claudemeter.widget")
            .appendingPathComponent("Data/Documents/api-spend.json")
    }

    private func deliverToWidget(_ snapshot: ApiSpendSnapshot) {
        let url = Self.widgetInboxURL()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try? data.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Disk cache

    private static var cacheURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeMeter", isDirectory: true)
            .appendingPathComponent("last-api-spend.json")
    }

    private static func readCache() -> ApiSpendSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(ApiSpendSnapshot.self, from: data)
    }

    private static func writeCache(_ snapshot: ApiSpendSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try? data.write(to: cacheURL, options: .atomic)
    }
}
```

- [ ] **Step 2: Verify it compiles with no warnings**

Run: `swift build -c release 2>&1 | tail -5`
Expected: no errors, no warnings

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeMeter/App/ApiSpendStore.swift
git commit -m "feat: publish API spend and deliver it to the widget container"
```

---

### Task 7: Dropdown section

**Files:**
- Create: `Sources/ClaudeMeter/Views/ApiSpendSection.swift`
- Modify: `Sources/ClaudeMeter/Views/MenuContentView.swift`

**Interfaces:**
- Consumes: `ApiSpendStore` (Task 6), `Formatting.usd` (Task 2)
- Produces: `ApiSpendSection` — `init(now: Date)`; reads the store from the environment

When no key is set the section renders **nothing**, so users who don't track API spend see no change.

- [ ] **Step 1: Write the view**

```swift
import ClaudeMeterCore
import SwiftUI

/// "API" block in the dropdown: today's spend, month to date, and the top models.
/// Renders nothing at all when no admin key is configured.
struct ApiSpendSection: View {
    @EnvironmentObject var store: ApiSpendStore
    @Environment(\.textScale) private var scale
    let now: Date

    var body: some View {
        if store.hasKey {
            VStack(alignment: .leading, spacing: scale.pt(6)) {
                Divider()
                Text("API")
                    .font(scale.font(11, weight: .semibold))
                    .foregroundStyle(.secondary)

                if let snapshot = store.snapshot {
                    row("Today", Formatting.usd(snapshot.todayUSD(now: now)))
                    row("Month to date", Formatting.usd(snapshot.totalUSD))
                    ForEach(snapshot.byModel.prefix(3), id: \.model) { entry in
                        row(shortModel(entry.model), Formatting.usd(entry.amountUSD), indented: true)
                    }
                } else if store.isLoading {
                    Text("Loading…")
                        .font(scale.font(11))
                        .foregroundStyle(.secondary)
                }

                if let error = store.errorMessage {
                    Text(error)
                        .font(scale.font(10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ title: String, _ value: String, indented: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(scale.font(indented ? 10 : 11))
                .foregroundStyle(indented ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.leading, indented ? scale.pt(10) : 0)
            Spacer()
            Text(value)
                .font(scale.font(indented ? 10 : 11))
                .monospacedDigit()
                .foregroundStyle(indented ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
    }

    /// `claude-sonnet-5` reads better as `sonnet-5` in a narrow dropdown.
    private func shortModel(_ model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }
}
```

- [ ] **Step 2: Wire it into the dropdown**

`MenuContentView` takes its dependencies as `@EnvironmentObject`, not init parameters — follow that pattern exactly.

In `Sources/ClaudeMeter/Views/MenuContentView.swift`, add one property beside the existing four (after `@EnvironmentObject var updates: UpdateService`):

```swift
    @EnvironmentObject var apiSpend: ApiSpendStore
```

In `var body`, inside the `if auth.isSignedIn { … }` branch, add the section after `signedInFooter`:

```swift
            if auth.isSignedIn {
                usageContent
                Divider()
                signedInFooter
                ApiSpendSection(now: now)
            } else {
```

In `Sources/ClaudeMeter/App/AppDelegate.swift`, declare the store beside the other lazy properties (near `private lazy var updates = UpdateService(settings: settings)`):

```swift
    private let apiSpend = ApiSpendStore()
```

Start it in `applicationDidFinishLaunching`, right after `sessionMonitor.start()`:

```swift
        // Cost data is daily-granularity and trails usage by ~5 min, so this ticks slowly.
        apiSpend.start()
```

Inject it into the popover in `openPopover()`, alongside the existing `.environmentObject` calls:

```swift
        .environmentObject(updates)
        .environmentObject(apiSpend)
```

And refresh on open — throttled to 5 minutes inside the store — by adding this just before `popover.show(...)` in `openPopover()`:

```swift
        Task { await apiSpend.refresh() }
```

- [ ] **Step 3: Build and check for warnings**

Run: `swift build -c release 2>&1 | tail -5`
Expected: no errors, no warnings

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeMeter/Views/ApiSpendSection.swift Sources/ClaudeMeter/Views/MenuContentView.swift Sources/ClaudeMeter/App/AppDelegate.swift
git commit -m "feat: show API spend in the dropdown"
```

---

### Task 8: Settings — key entry, instructions, Verify

**Files:**
- Create: `Sources/ClaudeMeter/Views/ApiSettingsSection.swift`
- Modify: `Sources/ClaudeMeter/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `AdminKeyStore` (Task 4), `CostClient.verifyOrganization()` (Task 5), `AdminKey` (Task 1), `ApiSpendStore` (Task 6)
- Produces: `ApiSettingsSection` — `init(spend: ApiSpendStore)`

- [ ] **Step 1: Write the view**

```swift
import ClaudeMeterCore
import SwiftUI

/// Settings → General block for the Claude API cost tracking credential.
struct ApiSettingsSection: View {
    @ObservedObject var spend: ApiSpendStore

    @State private var entry = ""
    @State private var status: Status = .idle
    @State private var hasKey = AdminKeyStore().hasKey

    private enum Status: Equatable {
        case idle
        case verifying
        case verified(String)
        case failed(String)
    }

    private let keys = AdminKeyStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude API spend").font(.headline)

            if hasKey {
                HStack {
                    Label(organizationLabel, systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Verify") { verify() }
                    Button("Remove") { remove() }
                }
            } else {
                SecureField("sk-ant-admin01-…", text: $entry)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") { save() }
                        .disabled(AdminKey(entry) == nil)
                    if case .verifying = status { ProgressView().controlSize(.small) }
                }
            }

            if case let .failed(message) = status {
                Text(message).font(.caption).foregroundStyle(.red)
            }

            instructions
        }
    }

    private var organizationLabel: String {
        if case let .verified(name) = status { return name }
        return "Admin key saved"
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How to get a key")
                .font(.caption).bold()
            Text("""
            1. Open platform.claude.com → Settings → Admin keys
            2. Click Create key, name it, and copy the secret — it's shown only once
            3. Paste it above

            Requires an organization (individual accounts can't use the Admin API) and \
            the admin role in it.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("A Console admin key carries full access to your organization, including \
            member management — Console keys have no read-only option. It is stored in your \
            Keychain and sent only to api.anthropic.com.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("Open Admin keys settings",
                 destination: URL(string: "https://platform.claude.com/settings/admin-keys")!)
                .font(.caption)
        }
        .padding(.top, 4)
    }

    private func save() {
        guard let key = AdminKey(entry) else { return }
        do {
            try keys.save(key)
            entry = ""
            hasKey = true
            verify()
        } catch {
            status = .failed("Couldn't save to the Keychain: \(error.localizedDescription)")
        }
    }

    private func verify() {
        status = .verifying
        Task {
            do {
                let name = try await CostClient().verifyOrganization()
                status = .verified(name)
                await spend.refresh(force: true)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                status = .failed(message)
            }
        }
    }

    private func remove() {
        keys.clear()
        hasKey = false
        status = .idle
        spend.reset()
    }
}
```

- [ ] **Step 2: Wire it into Settings**

`SettingsView` takes explicit init parameters (unlike `MenuContentView`), so the store is threaded through `SettingsWindowController`.

In `Sources/ClaudeMeter/Views/SettingsView.swift`, add a property beside the existing three:

```swift
    @ObservedObject var apiSpend: ApiSpendStore
```

and place the section in `generalTab`, below the existing update settings section:

```swift
            ApiSettingsSection(spend: apiSpend)
```

In `Sources/ClaudeMeter/App/SettingsWindowController.swift`, add the stored property, the init parameter, and pass it through:

```swift
    private let apiSpend: ApiSpendStore

    init(settings: Settings, auth: AuthModel, updates: UpdateService, apiSpend: ApiSpendStore) {
        self.settings = settings
        self.auth = auth
        self.updates = updates
        self.apiSpend = apiSpend
        super.init()
    }
```

and at the `SettingsView` construction site:

```swift
            let hosting = NSHostingController(
                rootView: SettingsView(
                    settings: settings, auth: auth, updates: updates, apiSpend: apiSpend,
                ),
            )
```

Finally, in `AppDelegate`, update the `settingsWindow` property to pass the same instance:

```swift
    private lazy var settingsWindow = SettingsWindowController(
        settings: settings, auth: auth, updates: updates, apiSpend: apiSpend,
    )
```

- [ ] **Step 3: Build and check for warnings**

Run: `swift build -c release 2>&1 | tail -5`
Expected: no errors, no warnings

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeMeter/Views/ApiSettingsSection.swift Sources/ClaudeMeter/Views/SettingsView.swift Sources/ClaudeMeter/App/SettingsWindowController.swift
git commit -m "feat: add the admin key field and setup instructions to Settings"
```

---

### Task 9: API spend widget

**Files:**
- Modify: `Widget/ClaudeMeterWidget.swift`

**Interfaces:**
- Consumes: `ApiSpendSnapshot` (Task 2), the file written by `ApiSpendStore.widgetInboxURL()` (Task 6)
- Produces: a fifth widget kind, `ClaudeApiSpend`, in `ClaudeMeterWidgetBundle`

The widget performs **no network and no Keychain access** — it only reads the JSON the app delivers into its own container.

- [ ] **Step 1: Add the entry, provider and view**

Append to `Widget/ClaudeMeterWidget.swift`:

```swift
// MARK: - API spend widget

struct ApiSpendEntry: TimelineEntry {
    let date: Date
    let snapshot: ApiSpendSnapshot?
}

/// Reads `api-spend.json` from the widget's own container Documents — the app cannot
/// deliver into the App Group container that a sandboxed widget can read.
struct ApiSpendProvider: TimelineProvider {
    func placeholder(in _: Context) -> ApiSpendEntry {
        ApiSpendEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in _: Context, completion: @escaping (ApiSpendEntry) -> Void) {
        completion(ApiSpendEntry(date: Date(), snapshot: Self.read()))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<ApiSpendEntry>) -> Void) {
        let entry = ApiSpendEntry(date: Date(), snapshot: Self.read())
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private static func read() -> ApiSpendSnapshot? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("api-spend.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ApiSpendSnapshot.self, from: data)
    }
}

struct ApiSpendWidgetView: View {
    let entry: ApiSpendEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("API").font(.caption2).foregroundStyle(.secondary)
            if let snapshot = entry.snapshot {
                Text(Formatting.usd(snapshot.totalUSD))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("this month").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("Today \(Formatting.usd(snapshot.todayUSD(now: entry.date)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Spacer(minLength: 0)
                Text("Add an admin key in ClaudeMeter Settings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct ApiSpendWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeApiSpend", provider: ApiSpendProvider()) { entry in
            ApiSpendWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("API Spend")
        .description("Your Claude API spend this month.")
        .supportedFamilies([.systemSmall])
    }
}
```

- [ ] **Step 2: Register it in the bundle**

Modify `ClaudeMeterWidgetBundle` (near the end of the file) to add `ApiSpendWidget()`:

```swift
@main
struct ClaudeMeterWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeMeterWidget()
        SessionGaugeWidget()
        WeeklyGaugeWidget()
        ModelGaugeWidget()
        ApiSpendWidget()
    }
}
```

- [ ] **Step 3: Build the full app + widget**

Run: `./build.sh --install`
Expected: builds and installs the app **with** the widget extension.

**Then re-register the appex**, or the new kind won't appear in the gallery — `chronod` caches supported widget kinds:

```bash
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
pluginkit -r /Applications/ClaudeMeter.app/Contents/PlugIns/ClaudeMeterWidget.appex
pluginkit -a /Applications/ClaudeMeter.app/Contents/PlugIns/ClaudeMeterWidget.appex
"$LSREG" -f /Applications/ClaudeMeter.app
killall chronod
```

Verify exactly one registration: `"$LSREG" -dump | grep ClaudeMeterWidget.appex` should list only the `/Applications` path.

- [ ] **Step 4: Commit**

```bash
git add Widget/ClaudeMeterWidget.swift
git commit -m "feat: add an API spend widget"
```

---

### Task 10: Docs and quality gates

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: Document the subsystem in CLAUDE.md**

Add a section after the self-update feature description:

```markdown
### API spend feature (Claude API cost, separate credential)

Subscription usage and **API spend** are different products with different logins. API spend
comes from the **documented** Admin API (`GET /v1/organizations/cost_report`), authenticated
with a Console **Admin API key** (`sk-ant-admin01-…`) held in ClaudeMeter's own Keychain item
`com.jakubzak.claudemeter.adminkey`.

- **Core** (pure/TDD): `AdminKey` (prefix validation), `CostReportDecoder` → `ApiSpendSnapshot`
  (`CostDay` / `ModelSpend`), `Formatting.usd`.
- **App**: `AdminKeyStore`, `CostClient` (paginating), `ApiSpendStore` (@MainActor, 15-min tick
  + throttled dropdown-open refresh), `ApiSpendSection`, `ApiSettingsSection`.
- **Widget**: kind `ClaudeApiSpend`, reading `api-spend.json` from its own container.

**`amount` is a decimal string in CENTS, not dollars** — `"103.1554"` is $1.03. Reading it as
dollars overstates spend 100×. The division lives in `CostReportDecoder` alone and is pinned by
a regression test. **`limit` defaults to 7 daily buckets** regardless of the date range and
silently truncates a month query, so `CostClient` always sends it and follows
`has_more`/`next_page`. Input and output arrive as separate rows per day and must be summed.

Buckets are UTC-aligned; we present UTC days so figures match the invoice, which means "Today"
can look off late in a local evening. The Admin API needs an **organization** — individual
accounts get nothing (403). There is **no documented balance endpoint**; when one ships it
becomes another field on `ApiSpendSnapshot`.
```

- [ ] **Step 2: Mention the feature in README.md**

Add API spend to the feature list, noting it needs a Console admin key and an organization.

- [ ] **Step 3: Run the full local gate**

Run: `swiftformat . && swiftlint --strict && scripts/coverage-gate.sh`
Expected: formatting clean, zero lint violations, core coverage ≥ 80%

- [ ] **Step 4: Commit and push**

```bash
git add CLAUDE.md README.md
git commit -m "docs: document the API spend subsystem"
git push -u origin feat/api-spend-tracking
```

- [ ] **Step 5: Open the PR**

Title: `feat(api): track Claude API spend in the dropdown and a widget`

Body must include:

```markdown
## Release notes

- ✨ Track your API spend right in the dropdown — today and month to date, broken down by model
- ✨ Add a Console admin key in Settings to turn on API cost tracking
- ✨ New widget for API spend, so the month's total sits on your desktop
```
