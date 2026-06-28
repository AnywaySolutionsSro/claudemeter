# Live Sessions — Phase 1 (Core Engine) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure, dependency-free core that turns Claude Code transcript files into per-session token-usage summaries with a "running" flag and a widget-ready snapshot.

**Architecture:** Pure value types + pure functions in the `ClaudeMeterCore` SwiftPM target. No filesystem, no process probing, no UI — all I/O is injected by callers in later phases. Parsing is lenient (skip bad lines, never throw). Everything is `Sendable` and `Codable` so later phases can move it across actors and serialize it for the widget.

**Tech Stack:** Swift 6.3, SwiftPM, `Foundation.JSONSerialization` for lenient decode, `swift-testing` (`import Testing`) for new tests.

## Global Constraints

- Swift tools version **5.9**, platform floor **macOS 13**, toolchain Swift **6.3**.
- All new public types are `public`, `Sendable`, `Equatable`; serializable ones are `Codable`.
- **Token headline total = `input + output + cacheCreation`.** Cache-read tokens are tracked separately, never folded into the headline.
- Use **top-level** `usage` fields, never the `iterations[]` breakdown.
- Parser **never throws** on a malformed line — it skips and counts.
- New tests use `swift-testing`; existing XCTest suites stay untouched.
- Run the whole suite with `swift test`. Run one suite with `swift test --filter <Name>`.

---

### Task 1: TokenBreakdown value type

**Files:**
- Create: `Sources/ClaudeMeterCore/Models/TokenBreakdown.swift`
- Test: `Tests/ClaudeMeterCoreTests/TokenBreakdownTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct TokenBreakdown: Equatable, Sendable, Codable`
  - props `let input: Int`, `let output: Int`, `let cacheCreation: Int`, `let cacheRead: Int`
  - `init(input:output:cacheCreation:cacheRead:)` with all defaults `0`
  - computed `var total: Int { input + output + cacheCreation }`
  - `static func + (lhs:rhs:) -> TokenBreakdown` summing all four fields
  - `static let zero = TokenBreakdown()`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import ClaudeMeterCore

@Suite struct TokenBreakdownTests {
    @Test func totalExcludesCacheRead() {
        let t = TokenBreakdown(input: 100, output: 20, cacheCreation: 5, cacheRead: 9_000)
        #expect(t.total == 125)
    }

    @Test func additionSumsEveryField() {
        let a = TokenBreakdown(input: 1, output: 2, cacheCreation: 3, cacheRead: 4)
        let b = TokenBreakdown(input: 10, output: 20, cacheCreation: 30, cacheRead: 40)
        #expect(a + b == TokenBreakdown(input: 11, output: 22, cacheCreation: 33, cacheRead: 44))
    }

    @Test func zeroIsAdditiveIdentity() {
        let a = TokenBreakdown(input: 7, output: 8, cacheCreation: 9, cacheRead: 10)
        #expect(a + .zero == a)
    }

    @Test func defaultsAreZero() {
        #expect(TokenBreakdown() == .zero)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TokenBreakdownTests`
Expected: FAIL — cannot find `TokenBreakdown` in scope.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Token counts for a single message or an aggregate of messages.
///
/// `total` deliberately excludes `cacheRead`: cache-read tokens repeat the cached
/// prefix on every turn, so summing them across a session inflates the number into
/// the millions and misrepresents real consumption.
public struct TokenBreakdown: Equatable, Sendable, Codable {
    public let input: Int
    public let output: Int
    public let cacheCreation: Int
    public let cacheRead: Int

    public init(input: Int = 0, output: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
    }

    public var total: Int { input + output + cacheCreation }

    public static let zero = TokenBreakdown()

    public static func + (lhs: TokenBreakdown, rhs: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TokenBreakdownTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeMeterCore/Models/TokenBreakdown.swift Tests/ClaudeMeterCoreTests/TokenBreakdownTests.swift
git commit -m "feat(core): TokenBreakdown value type"
```

---

### Task 2: SessionOrigin and RunningState enums

**Files:**
- Create: `Sources/ClaudeMeterCore/Models/SessionOrigin.swift`
- Create: `Sources/ClaudeMeterCore/Models/RunningState.swift`
- Test: `Tests/ClaudeMeterCoreTests/SessionEnumsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum SessionOrigin: String, Sendable, Codable, CaseIterable { case cli, desktop }`
  - `enum RunningState: String, Sendable, Codable { case running, idle }`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import ClaudeMeterCore

@Suite struct SessionEnumsTests {
    @Test func originRoundTripsRawValue() {
        #expect(SessionOrigin(rawValue: "cli") == .cli)
        #expect(SessionOrigin(rawValue: "desktop") == .desktop)
        #expect(SessionOrigin.allCases.count == 2)
    }

    @Test func runningStateRoundTripsRawValue() {
        #expect(RunningState(rawValue: "running") == .running)
        #expect(RunningState(rawValue: "idle") == .idle)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionEnumsTests`
Expected: FAIL — cannot find `SessionOrigin` / `RunningState`.

- [ ] **Step 3: Write minimal implementation**

`Sources/ClaudeMeterCore/Models/SessionOrigin.swift`:

```swift
/// Where a session's transcript came from.
public enum SessionOrigin: String, Sendable, Codable, CaseIterable {
    /// Terminal `claude` CLI (`~/.claude/projects`).
    case cli
    /// Claude desktop app agent/Cowork session.
    case desktop
}
```

`Sources/ClaudeMeterCore/Models/RunningState.swift`:

```swift
/// Whether a session is believed to still be live.
public enum RunningState: String, Sendable, Codable {
    case running
    case idle
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionEnumsTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeMeterCore/Models/SessionOrigin.swift Sources/ClaudeMeterCore/Models/RunningState.swift Tests/ClaudeMeterCoreTests/SessionEnumsTests.swift
git commit -m "feat(core): SessionOrigin and RunningState enums"
```

---

### Task 3: SessionUsage value type

**Files:**
- Create: `Sources/ClaudeMeterCore/Models/SessionUsage.swift`
- Test: `Tests/ClaudeMeterCoreTests/SessionUsageTests.swift`

**Interfaces:**
- Consumes: `TokenBreakdown`, `SessionOrigin`, `RunningState`.
- Produces:
  - `struct SessionUsage: Equatable, Sendable, Codable, Identifiable`
  - `let id: String` (session UUID / filename stem)
  - `let origin: SessionOrigin`
  - `let projectPath: String`
  - `var projectName: String` (last path component of `projectPath`, or `projectPath` if empty)
  - `let title: String?`
  - `let models: [String]` (sorted, unique)
  - `let tokens: TokenBreakdown`
  - `let messageCount: Int`
  - `let firstActivity: Date`
  - `let lastActivity: Date`
  - `let burnRate: Double` (tokens/min over the trailing window; `0` when unknown)
  - `var running: RunningState` (settable so `RunningResolver` can return updated copies)
  - `var totalTokens: Int { tokens.total }`
  - `var cacheReadTokens: Int { tokens.cacheRead }`
  - memberwise `init(...)` with `running` defaulting to `.idle` and `title` to `nil`
  - `func withRunning(_ state: RunningState) -> SessionUsage` returning a copy

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct SessionUsageTests {
    private func make(path: String) -> SessionUsage {
        SessionUsage(
            id: "abc", origin: .cli, projectPath: path, title: nil,
            models: ["claude-opus-4-8"], tokens: TokenBreakdown(input: 10, output: 5, cacheRead: 99),
            messageCount: 1, firstActivity: .init(timeIntervalSince1970: 0),
            lastActivity: .init(timeIntervalSince1970: 60), burnRate: 0
        )
    }

    @Test func projectNameIsLastPathComponent() {
        #expect(make(path: "/Users/x/code/movixtar").projectName == "movixtar")
    }

    @Test func projectNameFallsBackToRawPath() {
        #expect(make(path: "movixtar").projectName == "movixtar")
    }

    @Test func totalsDelegateToTokenBreakdown() {
        let s = make(path: "/a/b")
        #expect(s.totalTokens == 15)
        #expect(s.cacheReadTokens == 99)
    }

    @Test func withRunningReturnsUpdatedCopy() {
        let s = make(path: "/a/b")
        #expect(s.running == .idle)
        #expect(s.withRunning(.running).running == .running)
    }

    @Test func roundTripsThroughCodable() throws {
        let s = make(path: "/a/b")
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(SessionUsage.self, from: data) == s)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionUsageTests`
Expected: FAIL — cannot find `SessionUsage`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Aggregated token usage for one Claude Code session (one transcript file).
public struct SessionUsage: Equatable, Sendable, Codable, Identifiable {
    public let id: String
    public let origin: SessionOrigin
    public let projectPath: String
    public let title: String?
    public let models: [String]
    public let tokens: TokenBreakdown
    public let messageCount: Int
    public let firstActivity: Date
    public let lastActivity: Date
    public let burnRate: Double
    public var running: RunningState

    public init(
        id: String,
        origin: SessionOrigin,
        projectPath: String,
        title: String? = nil,
        models: [String],
        tokens: TokenBreakdown,
        messageCount: Int,
        firstActivity: Date,
        lastActivity: Date,
        burnRate: Double,
        running: RunningState = .idle
    ) {
        self.id = id
        self.origin = origin
        self.projectPath = projectPath
        self.title = title
        self.models = models
        self.tokens = tokens
        self.messageCount = messageCount
        self.firstActivity = firstActivity
        self.lastActivity = lastActivity
        self.burnRate = burnRate
        self.running = running
    }

    public var projectName: String {
        let name = (projectPath as NSString).lastPathComponent
        return name.isEmpty ? projectPath : name
    }

    public var totalTokens: Int { tokens.total }
    public var cacheReadTokens: Int { tokens.cacheRead }

    public func withRunning(_ state: RunningState) -> SessionUsage {
        var copy = self
        copy.running = state
        return copy
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionUsageTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeMeterCore/Models/SessionUsage.swift Tests/ClaudeMeterCoreTests/SessionUsageTests.swift
git commit -m "feat(core): SessionUsage value type"
```

---

### Task 4: TranscriptParser — per-line usage extraction

**Files:**
- Create: `Sources/ClaudeMeterCore/Services/TranscriptParser.swift`
- Test: `Tests/ClaudeMeterCoreTests/TranscriptParserTests.swift`

**Interfaces:**
- Consumes: `TokenBreakdown`.
- Produces:
  - `struct AssistantUsageRecord: Equatable, Sendable` with `let timestamp: Date`, `let model: String?`, `let cwd: String?`, `let tokens: TokenBreakdown`.
  - `struct ParsedTranscript: Equatable, Sendable` with `let records: [AssistantUsageRecord]`, `let malformedLineCount: Int`.
  - `struct TranscriptParser: Sendable`
    - `init()`
    - `func parseLine(_ line: String) -> AssistantUsageRecord?` — returns `nil` for blank lines, non-JSON, non-`assistant` records, and assistant records lacking `usage`.
    - `func parse(_ lines: [String]) -> ParsedTranscript` — applies `parseLine`, collecting records and counting lines that are non-blank, valid JSON objects of `type == "assistant"` **but** failed to yield a record (defensive malformed counter). Blank lines and non-assistant lines are NOT counted as malformed.

**Reference — real assistant record shape (fields we read):**
```json
{"type":"assistant","timestamp":"2026-06-28T17:49:06.352Z","cwd":"/Users/x/code",
 "message":{"model":"claude-opus-4-8","usage":{"input_tokens":28046,
 "cache_creation_input_tokens":19109,"cache_read_input_tokens":15840,"output_tokens":414}}}
```
`timestamp` is ISO-8601; reuse the existing `ISODate.parse(_:)` helper in `ClaudeMeterCore`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct TranscriptParserTests {
    private let parser = TranscriptParser()

    private let assistantLine = #"""
    {"type":"assistant","timestamp":"2026-06-28T17:49:06.352Z","cwd":"/Users/x/code","message":{"model":"claude-opus-4-8","usage":{"input_tokens":28046,"cache_creation_input_tokens":19109,"cache_read_input_tokens":15840,"output_tokens":414}}}
    """#

    @Test func parsesAssistantUsage() throws {
        let r = try #require(parser.parseLine(assistantLine))
        #expect(r.model == "claude-opus-4-8")
        #expect(r.cwd == "/Users/x/code")
        #expect(r.tokens == TokenBreakdown(input: 28046, output: 414, cacheCreation: 19109, cacheRead: 15840))
        #expect(r.timestamp == ISODate.parse("2026-06-28T17:49:06.352Z"))
    }

    @Test func ignoresNonAssistantLines() {
        #expect(parser.parseLine(#"{"type":"user","message":{"content":"hi"}}"#) == nil)
        #expect(parser.parseLine(#"{"type":"mode","mode":"normal"}"#) == nil)
    }

    @Test func ignoresBlankAndGarbageLines() {
        #expect(parser.parseLine("") == nil)
        #expect(parser.parseLine("   ") == nil)
        #expect(parser.parseLine("not json at all") == nil)
        #expect(parser.parseLine("{ broken json") == nil)
    }

    @Test func assistantWithoutUsageIsNil() {
        #expect(parser.parseLine(#"{"type":"assistant","message":{"model":"m"}}"#) == nil)
    }

    @Test func missingTokenFieldsDefaultToZero() throws {
        let line = #"{"type":"assistant","message":{"usage":{"output_tokens":5}}}"#
        let r = try #require(parser.parseLine(line))
        #expect(r.tokens == TokenBreakdown(input: 0, output: 5, cacheCreation: 0, cacheRead: 0))
    }

    @Test func parseCollectsRecordsAndCountsMalformed() {
        let lines = [
            assistantLine,
            "",                                                            // blank: ignored, not malformed
            #"{"type":"user"}"#,                                           // non-assistant: ignored, not malformed
            #"{"type":"assistant","message":{"model":"m"}}"#,             // assistant w/o usage: malformed
            assistantLine,
        ]
        let parsed = parser.parse(lines)
        #expect(parsed.records.count == 2)
        #expect(parsed.malformedLineCount == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TranscriptParserTests`
Expected: FAIL — cannot find `TranscriptParser` / `AssistantUsageRecord`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// One assistant message's usage, extracted from a transcript line.
public struct AssistantUsageRecord: Equatable, Sendable {
    public let timestamp: Date
    public let model: String?
    public let cwd: String?
    public let tokens: TokenBreakdown

    public init(timestamp: Date, model: String?, cwd: String?, tokens: TokenBreakdown) {
        self.timestamp = timestamp
        self.model = model
        self.cwd = cwd
        self.tokens = tokens
    }
}

/// Result of parsing a whole transcript file.
public struct ParsedTranscript: Equatable, Sendable {
    public let records: [AssistantUsageRecord]
    public let malformedLineCount: Int

    public init(records: [AssistantUsageRecord], malformedLineCount: Int) {
        self.records = records
        self.malformedLineCount = malformedLineCount
    }
}

/// Lenient JSONL transcript parser. Never throws: malformed lines are skipped
/// (and, when they were clearly meant to be assistant usage, counted).
public struct TranscriptParser: Sendable {
    public init() {}

    public func parseLine(_ line: String) -> AssistantUsageRecord? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "assistant",
              let message = root["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }

        let tokens = TokenBreakdown(
            input: int("input_tokens"),
            output: int("output_tokens"),
            cacheCreation: int("cache_creation_input_tokens"),
            cacheRead: int("cache_read_input_tokens")
        )

        let timestamp = (root["timestamp"] as? String).flatMap(ISODate.parse) ?? Date(timeIntervalSince1970: 0)
        return AssistantUsageRecord(
            timestamp: timestamp,
            model: message["model"] as? String,
            cwd: root["cwd"] as? String,
            tokens: tokens
        )
    }

    public func parse(_ lines: [String]) -> ParsedTranscript {
        var records: [AssistantUsageRecord] = []
        var malformed = 0
        for line in lines {
            if let record = parseLine(line) {
                records.append(record)
                continue
            }
            // Count lines that were clearly meant to be assistant usage but failed.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = trimmed.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               root["type"] as? String == "assistant" {
                malformed += 1
            }
        }
        return ParsedTranscript(records: records, malformedLineCount: malformed)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TranscriptParserTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeMeterCore/Services/TranscriptParser.swift Tests/ClaudeMeterCoreTests/TranscriptParserTests.swift
git commit -m "feat(core): lenient JSONL TranscriptParser"
```

---

### Task 5: SessionAggregator — fold records into a SessionUsage

**Files:**
- Create: `Sources/ClaudeMeterCore/Services/SessionAggregator.swift`
- Test: `Tests/ClaudeMeterCoreTests/SessionAggregatorTests.swift`

**Interfaces:**
- Consumes: `AssistantUsageRecord`, `ParsedTranscript`, `TokenBreakdown`, `SessionUsage`, `SessionOrigin`.
- Produces:
  - `struct SessionAggregator: Sendable`
    - `init(burnWindow: TimeInterval = 300)` — trailing window for burn rate, default 5 min.
    - `func aggregate(_ parsed: ParsedTranscript, id: String, projectPath: String, origin: SessionOrigin, title: String?, now: Date) -> SessionUsage?`
    - Returns `nil` when `parsed.records` is empty.
    - `tokens` = sum of all record tokens. `models` = sorted unique non-nil models. `messageCount` = records count. `firstActivity`/`lastActivity` = min/max timestamps. `projectPath` argument wins; if empty, fall back to the first record's `cwd ?? ""`.
    - `burnRate` = `Double(total tokens of records with timestamp > now - burnWindow) / (burnWindow / 60)` tokens-per-minute; `0` if no records fall in the window.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct SessionAggregatorTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func rec(_ ts: TimeInterval, _ model: String?, _ t: TokenBreakdown) -> AssistantUsageRecord {
        AssistantUsageRecord(timestamp: Date(timeIntervalSince1970: ts), model: model, cwd: "/c/proj", tokens: t)
    }

    @Test func emptyRecordsProduceNil() {
        let agg = SessionAggregator()
        #expect(agg.aggregate(ParsedTranscript(records: [], malformedLineCount: 0),
                              id: "x", projectPath: "/c/proj", origin: .cli, title: nil, now: now) == nil)
    }

    @Test func sumsTokensAndCollectsMetadata() throws {
        let agg = SessionAggregator()
        let parsed = ParsedTranscript(records: [
            rec(9_000, "claude-opus-4-8", TokenBreakdown(input: 10, output: 1, cacheCreation: 2, cacheRead: 100)),
            rec(9_500, "claude-sonnet-4-6", TokenBreakdown(input: 20, output: 3, cacheCreation: 4, cacheRead: 200)),
        ], malformedLineCount: 0)
        let s = try #require(agg.aggregate(parsed, id: "sid", projectPath: "/c/proj", origin: .cli, title: "T", now: now))
        #expect(s.id == "sid")
        #expect(s.title == "T")
        #expect(s.tokens == TokenBreakdown(input: 30, output: 4, cacheCreation: 6, cacheRead: 300))
        #expect(s.totalTokens == 40)
        #expect(s.models == ["claude-opus-4-8", "claude-sonnet-4-6"])
        #expect(s.messageCount == 2)
        #expect(s.firstActivity == Date(timeIntervalSince1970: 9_000))
        #expect(s.lastActivity == Date(timeIntervalSince1970: 9_500))
    }

    @Test func emptyProjectPathFallsBackToRecordCwd() throws {
        let agg = SessionAggregator()
        let parsed = ParsedTranscript(records: [rec(9_000, "m", TokenBreakdown(input: 1))], malformedLineCount: 0)
        let s = try #require(agg.aggregate(parsed, id: "sid", projectPath: "", origin: .cli, title: nil, now: now))
        #expect(s.projectPath == "/c/proj")
    }

    @Test func burnRateCountsOnlyRecordsInTrailingWindow() throws {
        let agg = SessionAggregator(burnWindow: 300) // 5 min
        let parsed = ParsedTranscript(records: [
            rec(now.timeIntervalSince1970 - 600, "m", TokenBreakdown(input: 1000)), // outside window
            rec(now.timeIntervalSince1970 - 60,  "m", TokenBreakdown(input: 50)),   // inside: total 50
        ], malformedLineCount: 0)
        let s = try #require(agg.aggregate(parsed, id: "sid", projectPath: "/c/proj", origin: .cli, title: nil, now: now))
        // 50 tokens over a 5-minute window => 10 tokens/min
        #expect(s.burnRate == 10)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionAggregatorTests`
Expected: FAIL — cannot find `SessionAggregator`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Folds the parsed records of one transcript into a single `SessionUsage`.
public struct SessionAggregator: Sendable {
    private let burnWindow: TimeInterval

    public init(burnWindow: TimeInterval = 300) {
        self.burnWindow = burnWindow
    }

    public func aggregate(
        _ parsed: ParsedTranscript,
        id: String,
        projectPath: String,
        origin: SessionOrigin,
        title: String?,
        now: Date
    ) -> SessionUsage? {
        let records = parsed.records
        guard !records.isEmpty else { return nil }

        let tokens = records.reduce(TokenBreakdown.zero) { $0 + $1.tokens }
        let models = Set(records.compactMap(\.model)).sorted()
        let timestamps = records.map(\.timestamp)
        let first = timestamps.min() ?? now
        let last = timestamps.max() ?? now

        let resolvedPath = projectPath.isEmpty ? (records.first?.cwd ?? "") : projectPath

        let windowStart = now.addingTimeInterval(-burnWindow)
        let windowTokens = records
            .filter { $0.timestamp > windowStart }
            .reduce(0) { $0 + $1.tokens.total }
        let minutes = burnWindow / 60
        let burnRate = minutes > 0 ? Double(windowTokens) / minutes : 0

        return SessionUsage(
            id: id,
            origin: origin,
            projectPath: resolvedPath,
            title: title,
            models: models,
            tokens: tokens,
            messageCount: records.count,
            firstActivity: first,
            lastActivity: last,
            burnRate: burnRate
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionAggregatorTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeMeterCore/Services/SessionAggregator.swift Tests/ClaudeMeterCoreTests/SessionAggregatorTests.swift
git commit -m "feat(core): SessionAggregator folds records into SessionUsage"
```

---

### Task 6: RunningResolver — assign live status

**Files:**
- Create: `Sources/ClaudeMeterCore/Services/RunningResolver.swift`
- Test: `Tests/ClaudeMeterCoreTests/RunningResolverTests.swift`

**Interfaces:**
- Consumes: `SessionUsage`, `SessionOrigin`, `RunningState`.
- Produces:
  - `struct RunningResolver: Sendable`
    - `init(desktopRecency: TimeInterval = 300)`
    - `func resolve(sessions: [SessionUsage], liveCwdCounts: [String: Int], desktopAppRunning: Bool, now: Date) -> [SessionUsage]`
    - **CLI** sessions: group by `projectPath`; for a group whose `liveCwdCounts[path]` is `K`, the `K` sessions with the latest `lastActivity` become `.running`, the rest `.idle`. Missing/`0` count → all `.idle`.
    - **Desktop** sessions: `.running` iff `desktopAppRunning` **and** `now - lastActivity <= desktopRecency`, else `.idle`.
    - Order of the returned array equals the input order.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct RunningResolverTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func session(_ id: String, _ origin: SessionOrigin, path: String, last: TimeInterval) -> SessionUsage {
        SessionUsage(id: id, origin: origin, projectPath: path, models: ["m"],
                     tokens: TokenBreakdown(input: 1), messageCount: 1,
                     firstActivity: .init(timeIntervalSince1970: 0),
                     lastActivity: .init(timeIntervalSince1970: last), burnRate: 0)
    }

    @Test func cliMarksMostRecentInCwdRunningUpToLiveCount() {
        let sessions = [
            session("old", .cli, path: "/p", last: 100),
            session("new", .cli, path: "/p", last: 900),
        ]
        let out = RunningResolver().resolve(sessions: sessions, liveCwdCounts: ["/p": 1], desktopAppRunning: false, now: now)
        #expect(out.first { $0.id == "new" }?.running == .running)
        #expect(out.first { $0.id == "old" }?.running == .idle)
    }

    @Test func cliTwoLiveProcessesMarkTwoNewest() {
        let sessions = [
            session("a", .cli, path: "/p", last: 100),
            session("b", .cli, path: "/p", last: 800),
            session("c", .cli, path: "/p", last: 900),
        ]
        let out = RunningResolver().resolve(sessions: sessions, liveCwdCounts: ["/p": 2], desktopAppRunning: false, now: now)
        #expect(out.first { $0.id == "a" }?.running == .idle)
        #expect(out.first { $0.id == "b" }?.running == .running)
        #expect(out.first { $0.id == "c" }?.running == .running)
    }

    @Test func cliNoLiveProcessAllIdle() {
        let sessions = [session("a", .cli, path: "/p", last: 900)]
        let out = RunningResolver().resolve(sessions: sessions, liveCwdCounts: [:], desktopAppRunning: false, now: now)
        #expect(out[0].running == .idle)
    }

    @Test func desktopRunningWhenAppAliveAndRecent() {
        let recent = session("d", .desktop, path: "/p", last: now.timeIntervalSince1970 - 60)
        let stale  = session("e", .desktop, path: "/p", last: now.timeIntervalSince1970 - 600)
        let out = RunningResolver(desktopRecency: 300).resolve(
            sessions: [recent, stale], liveCwdCounts: [:], desktopAppRunning: true, now: now)
        #expect(out.first { $0.id == "d" }?.running == .running)
        #expect(out.first { $0.id == "e" }?.running == .idle)
    }

    @Test func desktopIdleWhenAppNotRunning() {
        let recent = session("d", .desktop, path: "/p", last: now.timeIntervalSince1970 - 60)
        let out = RunningResolver().resolve(sessions: [recent], liveCwdCounts: [:], desktopAppRunning: false, now: now)
        #expect(out[0].running == .idle)
    }

    @Test func preservesInputOrder() {
        let sessions = [
            session("a", .cli, path: "/p", last: 100),
            session("b", .cli, path: "/p", last: 900),
        ]
        let out = RunningResolver().resolve(sessions: sessions, liveCwdCounts: ["/p": 1], desktopAppRunning: false, now: now)
        #expect(out.map(\.id) == ["a", "b"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RunningResolverTests`
Expected: FAIL — cannot find `RunningResolver`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Decides which sessions are still live, from process/app liveness signals.
public struct RunningResolver: Sendable {
    private let desktopRecency: TimeInterval

    public init(desktopRecency: TimeInterval = 300) {
        self.desktopRecency = desktopRecency
    }

    public func resolve(
        sessions: [SessionUsage],
        liveCwdCounts: [String: Int],
        desktopAppRunning: Bool,
        now: Date
    ) -> [SessionUsage] {
        // CLI: per project path, the K newest sessions are running (K = live process count).
        let cli = sessions.filter { $0.origin == .cli }
        var runningCLIIDs: Set<String> = []
        let groups = Dictionary(grouping: cli, by: \.projectPath)
        for (path, group) in groups {
            let k = liveCwdCounts[path] ?? 0
            guard k > 0 else { continue }
            let newest = group.sorted { $0.lastActivity > $1.lastActivity }.prefix(k)
            runningCLIIDs.formUnion(newest.map(\.id))
        }

        let staleCutoff = now.addingTimeInterval(-desktopRecency)
        return sessions.map { session in
            switch session.origin {
            case .cli:
                return session.withRunning(runningCLIIDs.contains(session.id) ? .running : .idle)
            case .desktop:
                let live = desktopAppRunning && session.lastActivity >= staleCutoff
                return session.withRunning(live ? .running : .idle)
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RunningResolverTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeMeterCore/Services/RunningResolver.swift Tests/ClaudeMeterCoreTests/RunningResolverTests.swift
git commit -m "feat(core): RunningResolver assigns live status"
```

---

### Task 7: SessionSnapshot — widget-ready payload

**Files:**
- Create: `Sources/ClaudeMeterCore/Models/SessionSnapshot.swift`
- Test: `Tests/ClaudeMeterCoreTests/SessionSnapshotTests.swift`

**Interfaces:**
- Consumes: `SessionUsage`, `RunningState`.
- Produces:
  - `struct SessionSnapshot: Equatable, Sendable, Codable`
    - `let generatedAt: Date`
    - `let sessions: [SessionUsage]`
    - `let totalTokens: Int`
    - `let runningCount: Int`
    - `static func make(from sessions: [SessionUsage], now: Date, limit: Int = 5) -> SessionSnapshot` — sorts by `totalTokens` desc, keeps the first `limit`; `totalTokens` is the sum across **all** input sessions (not just the kept ones); `runningCount` counts **all** input sessions with `running == .running`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct SessionSnapshotTests {
    private let now = Date(timeIntervalSince1970: 5_000)

    private func session(_ id: String, total: Int, running: RunningState) -> SessionUsage {
        SessionUsage(id: id, origin: .cli, projectPath: "/p/\(id)", models: ["m"],
                     tokens: TokenBreakdown(input: total), messageCount: 1,
                     firstActivity: now, lastActivity: now, burnRate: 0, running: running)
    }

    @Test func sortsByTotalDescAndAppliesLimit() {
        let snap = SessionSnapshot.make(from: [
            session("a", total: 10, running: .idle),
            session("b", total: 30, running: .running),
            session("c", total: 20, running: .idle),
        ], now: now, limit: 2)
        #expect(snap.sessions.map(\.id) == ["b", "c"])
    }

    @Test func totalsAndRunningCountSpanAllSessions() {
        let snap = SessionSnapshot.make(from: [
            session("a", total: 10, running: .running),
            session("b", total: 30, running: .running),
            session("c", total: 20, running: .idle),
        ], now: now, limit: 1)
        #expect(snap.totalTokens == 60)     // all three, not just the kept one
        #expect(snap.runningCount == 2)
        #expect(snap.generatedAt == now)
    }

    @Test func roundTripsThroughCodable() throws {
        let snap = SessionSnapshot.make(from: [session("a", total: 10, running: .idle)], now: now)
        let data = try JSONEncoder().encode(snap)
        #expect(try JSONDecoder().decode(SessionSnapshot.self, from: data) == snap)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionSnapshotTests`
Expected: FAIL — cannot find `SessionSnapshot`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Compact, serializable view of the current sessions, shared with the widget.
public struct SessionSnapshot: Equatable, Sendable, Codable {
    public let generatedAt: Date
    public let sessions: [SessionUsage]
    public let totalTokens: Int
    public let runningCount: Int

    public init(generatedAt: Date, sessions: [SessionUsage], totalTokens: Int, runningCount: Int) {
        self.generatedAt = generatedAt
        self.sessions = sessions
        self.totalTokens = totalTokens
        self.runningCount = runningCount
    }

    public static func make(from sessions: [SessionUsage], now: Date, limit: Int = 5) -> SessionSnapshot {
        let ranked = sessions.sorted { $0.totalTokens > $1.totalTokens }
        return SessionSnapshot(
            generatedAt: now,
            sessions: Array(ranked.prefix(limit)),
            totalTokens: sessions.reduce(0) { $0 + $1.totalTokens },
            runningCount: sessions.filter { $0.running == .running }.count
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionSnapshotTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeMeterCore/Models/SessionSnapshot.swift Tests/ClaudeMeterCoreTests/SessionSnapshotTests.swift
git commit -m "feat(core): SessionSnapshot widget payload"
```

---

### Task 8: Full-suite green + token formatter

**Files:**
- Modify: `Sources/ClaudeMeterCore/Formatting.swift` (append a token formatter)
- Test: `Tests/ClaudeMeterCoreTests/FormattingTests.swift` (append cases)

**Interfaces:**
- Consumes: nothing new.
- Produces: `public func formatTokenCount(_ tokens: Int) -> String` in the same namespace/style as existing `Formatting.swift` helpers — `999 -> "999"`, `1_500 -> "1.5K"`, `28_046 -> "28K"`, `1_250_000 -> "1.3M"`.

> Before writing, open `Sources/ClaudeMeterCore/Formatting.swift` and match its existing declaration style (free function vs. enum/static). The code below assumes free functions; adapt to match if it differs.

- [ ] **Step 1: Write the failing test (append to FormattingTests.swift)**

```swift
func testFormatTokenCount() {
    XCTAssertEqual(formatTokenCount(999), "999")
    XCTAssertEqual(formatTokenCount(1_500), "1.5K")
    XCTAssertEqual(formatTokenCount(28_046), "28K")
    XCTAssertEqual(formatTokenCount(1_250_000), "1.3M")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FormattingTests`
Expected: FAIL — `formatTokenCount` not found.

- [ ] **Step 3: Write minimal implementation (append to Formatting.swift)**

```swift
/// Compact human-readable token count: 999, 1.5K, 28K, 1.3M.
public func formatTokenCount(_ tokens: Int) -> String {
    let n = Double(tokens)
    switch tokens {
    case ..<1_000:
        return "\(tokens)"
    case ..<1_000_000:
        let k = n / 1_000
        return k < 10 ? String(format: "%.1fK", k) : String(format: "%.0fK", k)
    default:
        let m = n / 1_000_000
        return m < 10 ? String(format: "%.1fM", m) : String(format: "%.0fM", m)
    }
}
```

- [ ] **Step 4: Run the entire suite**

Run: `swift test`
Expected: PASS — all new suites plus the pre-existing XCTest suites are green.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeMeterCore/Formatting.swift Tests/ClaudeMeterCoreTests/FormattingTests.swift
git commit -m "feat(core): compact token count formatter"
```

---

## Self-Review

**Spec coverage (Phase 1 / layer A only):**
- TokenBreakdown + headline rule (input+output+cacheCreation, cache-read separate) → Tasks 1, 5. ✓
- Lenient parser, top-level usage fields, never throws → Task 4. ✓
- Per-session aggregation, burn rate, model set, first/last activity → Task 5. ✓
- Running assignment for CLI (process-cwd) and desktop (recency + app alive) → Task 6. ✓
- Widget-ready Codable snapshot → Task 7. ✓
- Origin badge data (`SessionOrigin`) + friendly title field → Tasks 2, 3. ✓
- swift-testing, Sendable/Codable, ≥80% core coverage → all tasks. ✓

**Deferred to later-phase plans (NOT in this plan, by design):** `TranscriptSource` filesystem enumeration (CLI + desktop roots, mtime cache), `ProcessProbe` (libproc), `SessionMonitor` actor, Sessions window (B), Settings window (C), XcodeGen + widget + App Group (D).

**Placeholder scan:** none — every code step is complete.

**Type consistency:** `TokenBreakdown(.zero, +, total)`, `SessionUsage.withRunning`, `RunningState.running/.idle`, `SessionOrigin.cli/.desktop` used identically across Tasks 1–7. `aggregate(...)` and `resolve(...)` signatures match their consumers. ✓
