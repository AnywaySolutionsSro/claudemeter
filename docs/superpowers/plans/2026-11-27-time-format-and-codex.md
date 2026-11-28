# Time format + Codex support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (Part A) a 12h/24h/System time-format setting across app, notifications and widgets; (Part B) Codex limits, sessions, notifications and terminal auto-resume beside Claude, colour-coded.

**Architecture:** Part A adds `ClockStyle` + one formatter in core and threads the choice to the widget via the snapshot files. Part B adds a separate `CodexScanner` (Codex transcripts are cumulative and need no subagent/dedup logic, so it does not share `SessionScanner`), turns the newest Codex `rate_limits` reading into an ordinary `UsageSnapshot` so the existing `UsageStats` refill/crossing logic, `AutoResumePlanner.gate` and notification code are reused unchanged, and tags sessions with `AgentTool`.

**Tech Stack:** Swift 6 (core strict), SwiftPM + XcodeGen app/widget, XCTest, SwiftUI, WidgetKit.

**Specs:** `docs/superpowers/specs/2026-11-27-time-format-design.md`, `docs/superpowers/specs/2026-11-27-codex-support-design.md`

## Global Constraints

- Two branches / two PRs: `feat/time-format` (Part A) first, then `feat/codex` (Part B) branched from it. PR titles `feat(settings): …` / `feat(codex): …`, each with a `## Release notes` section (1–3 emoji bullets, customer copy).
- Quality gate before every commit: `swiftformat . && swiftlint --strict && scripts/coverage-gate.sh` (zero warnings, core coverage ≥ 80%).
- Stored/shared models only gain **optional** fields; old `snapshot.json` / `api-spend.json` / armed set must still decode.
- Never read `~/.codex/auth.json`; never contact OpenAI.
- Colours: Claude `#D97757`, Codex `#10A37F`.
- Codex UI/notifications/pill toggle appear only when Codex is "present" (≥1 non-import session with non-zero tokens or a `rate_limits` reading).
- Local deploy before any push: `./build.sh --install` (never `--spm`); for Part B also purge chrono cache for the new widget kind (CLAUDE.md recipe).

## Review Focus

1. A Codex limit reading days old whose `resets_at` has passed → shown as 100% left, "reset at … · no reading since"; must not fire a spurious threshold alert. (Task B3 test `testPassedResetReadsAsFull`.)
2. Claude and Codex both have a "Weekly" window → notification ids, delivered-state and reset reminders must not overwrite each other. (Task B6 test `testNotificationIDsAreNamespacedByTool`.)
3. Codex Desktop helper / `app-server-daemon` process sitting in the same cwd as a terminal Codex → never armable, never typed into. (Task B4 test `testDaemonAndDesktopHelpersExcluded`.)
4. Imported Claude threads in `~/.codex/sessions` → not listed, don't make Codex "present". (Task B2 test `testImportedLegacyThreadsSkipped`.)
5. Old `snapshot.json` without `clockStyle` / `codexGauges` / `tool` → widget renders exactly as before. (Task A3 + B5 decode tests.)

---

## Part A — Time format (branch `feat/time-format`)

### Task A1: `ClockStyle` and the time formatter (core)

**Files:**
- Create: `Sources/ClaudeMeterCore/Models/ClockStyle.swift`
- Modify: `Sources/ClaudeMeterCore/Formatting+ResetMoment.swift`
- Test: `Tests/ClaudeMeterCoreTests/ClockStyleTests.swift`, extend `ResetMomentTests.swift`

**Interfaces — Produces:**
- `public enum ClockStyle: String, Codable, Sendable, CaseIterable { case system, twentyFour, twelve }` with `public func uses12Hour(locale: Locale) -> Bool` and `public var label: String` ("System", "24-hour", "12-hour").
- `Formatting.clockTime(_ date: Date, style: ClockStyle, timeZone: TimeZone = .current, locale: Locale = .current) -> String` → `"14:05"` / `"2:05 PM"`.
- `Formatting.dateTime(_ date: Date, style: ClockStyle, …) -> String` → `"27 Nov 14:05"` (replaces `.formatted(date: .abbreviated, time: .shortened)`).
- `Formatting.resetMoment(_:now:timeZone:locale:style: ClockStyle = .system)`.

- [ ] Write failing tests: `testTwelveForcesAMPM` (`clockTime(14:05 UTC, .twelve, UTC, en_GB) == "2:05 PM"`), `testTwentyFourForcesHH` (`en_US` + `.twentyFour` → `"14:05"`), `testSystemFollowsLocale` (en_US → `"2:05 PM"`, en_GB → `"14:05"`), `testResetMomentHonoursStyle` (`"tomorrow 2:05 PM"` with `.twelve`, en_GB), `testDateTime` (`"27 Nov 14:05"`).
- [ ] Run `swift test --filter ClockStyleTests` → FAIL (undefined).
- [ ] Implement; `uses12Hour(locale)` moves into `ClockStyle.system`.
- [ ] `swift test` → PASS. Commit `feat(settings): add ClockStyle and shared time formatter`.

### Task A2: Setting + every app call site

**Files:** `Sources/ClaudeMeter/Support/Settings.swift`, `Views/SettingsView.swift`, `Views/MenuContentView.swift:151`, `Views/SessionsView.swift:147`, `Views/ApiSpendSection.swift:85`, `Views/UpdateSettingsSection.swift:54,61,71`, `Support/NotificationManager.swift` (any time in bodies), every `Formatting.resetMoment` caller.

**Interfaces — Consumes:** A1. **Produces:** `Settings.clockStyle: ClockStyle` (`@Published`, key `"clockStyle"`, default `.system`).

- [ ] Add the setting and a "Time format" `Picker` in Settings → General.
- [ ] Replace each call site with `Formatting.clockTime` / `dateTime` / `resetMoment(style:)` reading `settings.clockStyle`. Verify: `grep -rn "time: .shortened" Sources` → no hits.
- [ ] `swift build -c release` clean. Commit `feat(settings): time format picker drives every app time`.

### Task A3: Widget follows the setting

**Files:** `SessionSnapshot.swift`, `ApiSpendSnapshot.swift`, `SessionMonitor.swift` (snapshot build), `ApiSpendStore.swift` (file write), `Widget/ClaudeMeterWidget.swift:228`, `Widget/ApiSpendWidget.swift:90`, `GaugeRingView` reset text.
**Produces:** `SessionSnapshot.clockStyle: ClockStyle?`, `ApiSpendSnapshot.clockStyle: ClockStyle?` (optional, `decodeIfPresent`; `nil` ⇒ `.system`).

- [ ] Failing tests: `testOldSnapshotDecodesWithoutClockStyle` (fixture JSON without the key → `clockStyle == nil`), `testClockStyleRoundTrips` for both snapshots.
- [ ] Implement fields; app writes `settings.clockStyle`; changing the setting forces a publish + `reloadAllTimelines()`.
- [ ] Widget uses `Formatting.clockTime(…, style: snapshot.clockStyle ?? .system)`.
- [ ] `scripts/coverage-gate.sh` passes. Commit `feat(widget): widgets follow the time format setting`.

### Task A4: Deploy locally, PR

- [ ] `swiftformat . && swiftlint --strict && scripts/coverage-gate.sh`.
- [ ] `./build.sh --install`; check dropdown, Settings, Sessions window and a widget in each of the 3 styles.
- [ ] **Stop for Jakub's OK**, then push and open PR `feat(settings): choose 12- or 24-hour time` with release note `✨ Pick 12-hour or 24-hour time in Settings — the dropdown, widgets and alerts follow it`.

---

## Part B — Codex (branch `feat/codex`, from `feat/time-format`)

### Task B1: `AgentTool` + session tagging

**Files:** Create `Sources/ClaudeMeterCore/Models/AgentTool.swift`; modify `SessionUsage.swift`, `SessionOrigin.swift`. Test `AgentToolTests.swift`.
**Produces:** `public enum AgentTool: String, Codable, Sendable { case claude, codex }`; `SessionUsage.tool: AgentTool?` + `var effectiveTool: AgentTool { tool ?? .claude }`; `SessionOrigin` gains `case codexCLI, codexDesktop`. `withRunning`/`withProjectPath` preserve `tool`.

- [ ] Tests: `testLegacySessionDecodesAsClaude` (JSON without `tool`), `testToolSurvivesCopies`.
- [ ] Implement, run, commit `feat(codex): tag sessions with their tool`.

### Task B2: Codex transcript parsing + discovery

**Files:** Create `Services/CodexTranscriptParser.swift`, `Services/CodexTranscriptSource.swift`, `Models/CodexLimitReading.swift`. Tests `CodexTranscriptParserTests.swift`, `CodexTranscriptSourceTests.swift`, fixtures under `Tests/ClaudeMeterCoreTests/Fixtures/codex/` (built from real files, conversation text replaced with `"x"`).
**Produces:**
- `struct CodexSessionState: Sendable, Equatable { var id, cwd, originator: String?; var model: String?; var tokens: TokenBreakdown; var firstActivity, lastActivity: Date?; var latestLimits: CodexLimitReading?; var isImportedLegacy: Bool }` and `func folding(_ lines: [String]) -> CodexSessionState` (pure, incremental).
- `struct CodexLimitReading: Sendable, Equatable, Codable { let limitID: String; let observedAt: Date; let windows: [CodexWindowReading]; let reachedType: String? }`, `struct CodexWindowReading { let usedPercent: Double; let windowMinutes: Int; let resetsAt: Date? }`.
- `CodexTranscriptSource: TranscriptDiscovering` (root `~/.codex/sessions`, recursive `rollout-*.jsonl`, id = `session_meta.payload.id` or filename suffix, title from `~/.codex/session_index.jsonl` `thread_name`, imported ids from `external_agent_session_imports.json`).
- Token mapping: input = `input_tokens − cached_input_tokens`, cacheRead = `cached_input_tokens`, output = `output_tokens`, cacheCreation = 0; last `token_count` wins.

- [ ] Tests: `testCumulativeTokensLastWins`, `testTokenMapping` (26_160_392/25_716_736/92_706 → input 443_656, cacheRead 25_716_736, output 92_706), `testRateLimitsParsed` (primary 4.0/10080/1796332812, secondary nil, limit_id "codex"), `testMalformedLinesIgnored`, `testImportedLegacyThreadsSkipped` (`history_mode:"legacy"` + id in imports file → `isImportedLegacy`; becomes non-import only if later non-zero tokens).
- [ ] Implement; run; commit `feat(codex): parse Codex transcripts and limit readings`.

### Task B3: Codex limits → `UsageSnapshot`

**Files:** Create `Services/CodexLimits.swift`. Test `CodexLimitsTests.swift`.
**Produces:** `enum CodexLimits { static func newest(_ readings: [CodexLimitReading]) -> CodexLimitReading?` (per `limitID`, newest `observedAt`; prefers `"codex"`) `; static func snapshot(from: CodexLimitReading, now: Date) -> UsageSnapshot }`. Mapping: `windowMinutes ≤ 300` → `fiveHour`, `≥ 10080` → `sevenDay`, else `sevenDay` if empty; `utilization = usedPercent`, **but 0 when `resetsAt ≤ now`**; `fetchedAt = observedAt`. Add `CodexLimits.isPastReset(window, now)` for the "no reading since" note.

- [ ] Tests: `testWeeklyOnlyPlan` (only `sevenDay` set, `fiveHour == nil`), `testPassedResetReadsAsFull`, `testRefillDetectedWhenResetPasses` (feed `UsageStats.refilledWindows(prev: snapshot(r, before), cur: snapshot(r, after))` → `[Weekly]` when used was 100), `testNewestPerLimitID`.
- [ ] Implement; run; commit `feat(codex): read Codex limits as a usage snapshot`.

### Task B4: Codex processes, cutoff detection, scanner

**Files:** Modify `Services/ProcessProbe.swift`; create `Services/CodexCutoffDetector.swift`, `Services/CodexScanner.swift`; modify `AutoResumePlanner.swift`. Tests `ProcessProbeTests.swift` (extend), `CodexCutoffDetectorTests.swift`, `CodexScannerTests.swift`, `AutoResumePlannerTests.swift` (extend).
**Produces:**
- `LibprocProcessProbe.isCodexTerminalExecutable(_ path: String) -> Bool` (contains `/.codex/packages/standalone/`; false for `app-server-daemon`, anything in `ChatGPT.app`); `ProcessProbing.liveCodexProcesses() -> [LiveProcess]` (protocol requirement with a default `[]` extension for fakes; real impl also requires a `/dev/tty*` tty).
- `CodexCutoffDetector.classify(tailLines:isRunning:) -> SessionEligibility`: last meaningful entry = `event_msg` `error` (or any payload text) containing "usage limit" / `token_count.rate_limits.rate_limit_reached_type != null` → `.eligibleCutoff`; `task_complete` → `.cleanlyFinished`; `task_started` w/o completion → `.running`; `response_item` message role `user` → `.awaitingUserInput`; else `.unknown`.
- `AutoResumePlanner.plan(…, classify: ([String]) -> SessionEligibility = { CutoffDetector().classify(tailLines: $0, isRunning: false) })` — new trailing param, existing callers unchanged.
- `actor CodexScanner { init(source: TranscriptDiscovering & CodexTranscriptSource-like, processProbe: ProcessProbing, …); func scan(now: Date) -> CodexScanResult }`, `struct CodexScanResult { sessions: [SessionUsage]; processes: [LiveProcess]; armableSessionIDs: [String]; limits: CodexLimitReading?; isPresent: Bool }`. Incremental per-file cache (mtime + byte offset + `CodexSessionState`) like `SessionScanner`; running via `RunningResolver` with Codex cwd counts (`desktopAppRunning: false`); armable only for `originator == "codex-tui"` + unique cwd process + drivable terminal.

- [ ] Tests: `testDaemonAndDesktopHelpersExcluded`, `testStandaloneCodexMatched`, cutoff cases (`testUsageLimitErrorIsCutoff` using the binary's text "You've hit your usage limit. Try again at 6:20 PM.", `testTaskCompleteIsFinished`, `testTrailingUserMessageAwaits`, `testReachedTypeIsCutoff`), `testDesktopSessionNeverArmable`, `testPlannerUsesInjectedClassifier`, `testIncrementalScanFoldsOnlyAppendedLines`.
- [ ] Implement; run; commit `feat(codex): scan Codex sessions and detect limit cutoffs`.

### Task B5: Wire into the app — monitor, auto-resume, snapshot, colours

**Files:** `App/SessionMonitor.swift`, `App/AutoResumeCoordinator.swift`, `App/AppDelegate.swift`, `SessionSnapshot.swift`, create `Sources/ClaudeMeterCore/Models/ToolPalette.swift` (hex values, used by app + widget), `Views/SessionsView.swift`, `Views/SessionRow.swift`.
**Produces:** `SessionMonitor.codexLimits: UsageSnapshot?`, `codexAsOf: Date?`, `codexPresent: Bool` (@Published); `SessionSnapshot.codexGauges: [UsageGauge]?`, `codexAsOf: Date?`; `ToolPalette.hex(for: AgentTool) -> UInt32` (`0xD97757`, `0x10A37F`). `AutoResumeCoordinator` holds per-tool state `[AgentTool: (lastWindows, window, lastRefillAt)]`; `handleSnapshot(tool:usage:sessions:processes:transcriptTail:classify:paths:parents:)`; Codex resume notification "▶︎ Resumed X (Codex)". `SessionMonitor.tailLines` searches the Codex root for codex sessions.

- [ ] Tests (core): `testSnapshotDecodesWithoutCodexFields`, `testCodexGaugesRoundTrip`.
- [ ] Monitor runs `CodexScanner` in the same 10-s refresh, merges sessions, publishes `codexGauges` (from `CodexLimits.snapshot(now:)`) into the widget snapshot; widget-reload structure key includes codex gauges.
- [ ] Coordinator runs the Claude plan and the Codex plan independently (armed set shared).
- [ ] Sessions window: coloured tool tag; Codex Desktop rows say "desktop — not resumable"; test-resume works for Codex terminal rows.
- [ ] Build; commit `feat(codex): monitor and auto-resume Codex terminal sessions`.

### Task B6: Notifications per tool

**Files:** `Support/NotificationManager.swift`, `App/AppDelegate.swift` (`handle(_ event:)`), `App/UsageStore.swift` (move `detectEvents` logic into a reusable core function), `Support/Settings.swift`, `Views/SettingsView.swift`. Create core `Services/LimitEvents.swift`; test `LimitEventsTests.swift`.
**Produces:** core `enum LimitEvent { case crossed(Double, LimitWindow, eta: TimeInterval?), reset(LimitWindow) }`, `LimitEvents.detect(previous: UsageSnapshot?, current: UsageSnapshot, now: Date) -> [LimitEvent]` (exact current UsageStore behaviour; UsageStore calls it). `NotificationManager.notifyThreshold/notifyRefill/scheduleResetReminder` gain `tool: AgentTool`: title prefix `"Claude · "` / `"Codex · "`, ids `"<tool>-threshold-<window.id>-<n>"`, `"<tool>-reset-reminder"`. `Settings.codexNotificationsEnabled` (default true). Codex events: `SessionMonitor` runs `LimitEvents.detect` on consecutive Codex snapshots (baseline = previous scan's, first scan seeds silently).

- [ ] Tests: `testDetectMatchesLegacyBehaviour` (port existing UsageStore cases), `testNotificationIDsAreNamespacedByTool` (pure id builder `NotificationIDs.threshold(tool:window:threshold:)`), `testStalePassedResetDoesNotCrossThreshold`.
- [ ] Implement; Settings shows "Claude limit alerts" + "Codex limit alerts" (latter only if `codexPresent`).
- [ ] Commit `feat(codex): separate limit notifications for Codex`.

### Task B7: Dropdown, menu-bar pill, widgets

**Files:** `Views/MenuContentView.swift`, create `Views/CodexSection.swift`, `Views/MenuBarLabel.swift`, `App/AppDelegate.swift` (`updateLabel`), `Settings.swift` (`showCodexInMenuBar`, default false), `Widget/ClaudeMeterWidget.swift`, `Widget/SingleGaugeWidgets.swift` (+ `CodexWeeklyGaugeWidget`, kind `CodexGaugeWeekly`, in bundle), header text "Sessions".
- [ ] Dropdown per the spec sketch: "● Claude" header over existing content; `CodexSection` (rows via existing `UsageRow` in Codex colour, "as of …" via `Formatting.clockTime`, "N running · M armed", "reset at … · no reading since").
- [ ] Pill: second green pill when `showCodexInMenuBar && codexPresent`.
- [ ] Widgets: gauge rings tinted by tool; medium shows Claude then Codex rings; session rows get a tool-coloured dot; new Codex Weekly widget.
- [ ] Build both targets; commit `feat(codex): show Codex in the dropdown, menu bar and widgets`.

### Task B8: Docs, deploy locally, PR

- [ ] CLAUDE.md: "Codex support" section (sources, import skip, reading→snapshot, reset rule, process matching, unverified cutoff + how to check it in logs).
- [ ] Gate: `swiftformat . && swiftlint --strict && scripts/coverage-gate.sh`.
- [ ] `./build.sh --install`; purge chrono cache for `CodexGaugeWeekly`; verify with the chronod kinds grep; manually: Codex section shows 96%-ish weekly, `codex` in iTerm shows as armable, test-resume types `continue` into it.
- [ ] **Stop for Jakub's OK**, then push and open PR `feat(codex): monitor Codex alongside Claude` with release notes `✨ See your Codex limits and sessions next to Claude's, each in its own colour`, `✨ Codex terminal sessions can auto-resume after a limit refills`, `✨ Separate limit alerts for Codex`.
