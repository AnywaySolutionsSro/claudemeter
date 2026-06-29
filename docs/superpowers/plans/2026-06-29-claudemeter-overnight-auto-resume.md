# ClaudeMeter Overnight Auto-Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user arm specific live Claude Code sessions so that, on each quota refresh, ClaudeMeter types `continue` into each armed session's exact iTerm2 tab — but only when that session was cut off mid-task by the usage limit and is now idle — repeating every reset until disarmed, with armed state shown and controllable (arm **and** disarm) from both the Sessions window and the widget.

**Architecture:** Pure, TDD'd logic lives in `ClaudeMeterCore` (cutoff detection, terminal detection, armed-set persistence, process model, widget-command model). AppKit/system integration lives in `ClaudeMeter` (coordinator, iTerm2 driver, sleep inhibitor, settings/UI, session→process correlation). The widget gains an armed indicator and an interactive disarm button backed by an App Intent that writes a request file the app applies (mirroring the existing one-way snapshot inbox, since the sandboxed widget cannot write the app's store directly).

**Tech Stack:** Swift 6.2 toolchain (Swift 5 language mode), SwiftPM two-target package + XcodeGen for the widget, Swift Testing (`import Testing`), AppKit/SwiftUI, libproc, IOKit power assertions, NSAppleScript (iTerm2 automation), WidgetKit + AppIntents.

## Global Constraints

- **Swift tools version:** 6.2; language mode `.v5` (`Package.swift`). Do not enable Swift 6 strict-concurrency mode.
- **Platform floor:** macOS 26.0 (`Package.swift` `platforms`, `project.yml` `deploymentTarget`).
- **Target split (strict):** all pure/testable logic goes in `ClaudeMeterCore` with tests in `Tests/ClaudeMeterCoreTests`; AppKit/system code goes in `ClaudeMeter`; widget UI/intent goes in `Widget`. `ClaudeMeterCore` must not import AppKit/SwiftUI/IOKit/AppIntents.
- **Tests:** Swift Testing only (`import Testing`, `@Suite`, `@Test`, `#expect`). Run with `swift test`. Keep core tests green.
- **Style:** prefer `let`, value types, files < 400 lines, immutability (`withRunning`-style copies), explicit error handling, no `print()` (use `NSLog`/`os.Logger` sparingly or typed errors).
- **App group / widget bundle id:** `group.com.jakubzak.claudemeter`; widget bundle id `com.jakubzak.claudemeter.ClaudeMeterWidget` (see `SnapshotStore.appGroupID`, `SessionMonitor.widgetBundleID`).
- **Continue default text:** `continue`. Feature is opt-in and persisted; arming survives app restart.
- **v1 terminal support:** iTerm2 only. Non-iTerm2 sessions are detected and shown with a disabled arm toggle.
- **Firing strategy (decided):** fire all eligible armed sessions with a small fixed stagger, no cap.
- **Widget interactivity (decided):** widget shows armed sessions AND offers per-session interactive **arm and disarm**; both also work from the Sessions window. Arming is offered only for **armable** (iTerm2 + running) sessions; the app re-validates arm requests before applying.

---

## File Structure

**Create (Core):**
- `Sources/ClaudeMeterCore/Models/LiveProcess.swift` — `LiveProcess` value type (pid, cwd, tty, ppid).
- `Sources/ClaudeMeterCore/Models/TerminalKind.swift` — terminal-app enum + `isDrivable`.
- `Sources/ClaudeMeterCore/Models/SessionEligibility.swift` — eligibility enum.
- `Sources/ClaudeMeterCore/Models/WidgetCommand.swift` — disarm-request model + Codable container.
- `Sources/ClaudeMeterCore/Services/CutoffDetector.swift` — eligibility over a transcript tail.
- `Sources/ClaudeMeterCore/Services/TerminalDetector.swift` — parent-PID chain → `TerminalKind`.
- `Sources/ClaudeMeterCore/Services/ArmedSessionsStore.swift` — persist `Set<String>` + read/write widget command file.

**Modify (Core):**
- `Sources/ClaudeMeterCore/Services/ProcessProbe.swift` — add `liveClaudeProcesses() -> [LiveProcess]` to `ProcessProbing`; libproc impl reads ppid + tty; `liveClaudeCwdCounts()` becomes a default derived from it.
- `Sources/ClaudeMeterCore/Models/SessionSnapshot.swift` — add `armedSessionIDs: [String]` (Codable, defaults empty).

**Create (App):**
- `Sources/ClaudeMeter/App/ArmedSessions.swift` — `@MainActor ObservableObject` wrapping `ArmedSessionsStore`.
- `Sources/ClaudeMeter/App/AutoResumeCoordinator.swift` — orchestrator.
- `Sources/ClaudeMeter/Support/SessionProcessIndex.swift` — session UUID → unique `LiveProcess`.
- `Sources/ClaudeMeter/Support/TerminalResumeDriver.swift` — driver protocol + errors.
- `Sources/ClaudeMeter/Support/ITermDriver.swift` — iTerm2 NSAppleScript impl.
- `Sources/ClaudeMeter/Support/SleepInhibitor.swift` — IOKit power assertion.

**Modify (App):**
- `Sources/ClaudeMeter/Support/Settings.swift` — `autoResumeEnabled`, `autoResumeContinueText`.
- `Sources/ClaudeMeter/Views/SettingsView.swift` — Auto-Resume section.
- `Sources/ClaudeMeter/Views/SessionsView.swift` — "N armed" header badge.
- `Sources/ClaudeMeter/Views/SessionRow.swift` — per-row arm toggle (enabled only for iTerm2).
- `Sources/ClaudeMeter/App/SessionMonitor.swift` — carry armed IDs + live processes + terminal kinds into published state/snapshot; apply pending widget commands.
- `Sources/ClaudeMeter/App/AppDelegate.swift` — instantiate + wire `ArmedSessions`, `AutoResumeCoordinator`, `SleepInhibitor`.

**Create (Widget):**
- `Widget/DisarmSessionIntent.swift` — App Intent that writes a disarm request.

**Modify (Widget):**
- `Widget/ClaudeMeterWidget.swift` — armed indicator + disarm button.

**Test files (Core):**
- `Tests/ClaudeMeterCoreTests/CutoffDetectorTests.swift`
- `Tests/ClaudeMeterCoreTests/TerminalDetectorTests.swift`
- `Tests/ClaudeMeterCoreTests/ArmedSessionsStoreTests.swift`
- `Tests/ClaudeMeterCoreTests/LiveProcessTallyTests.swift`
- `Tests/ClaudeMeterCoreTests/SessionSnapshotArmedTests.swift`
- `Tests/ClaudeMeterCoreTests/WidgetCommandTests.swift`

---

## Phase A — Core models & detection (pure, TDD)

### Task 1: `LiveProcess` model + probe extension (pid/cwd/tty/ppid)

**Files:**
- Create: `Sources/ClaudeMeterCore/Models/LiveProcess.swift`
- Modify: `Sources/ClaudeMeterCore/Services/ProcessProbe.swift`
- Test: `Tests/ClaudeMeterCoreTests/LiveProcessTallyTests.swift`

**Interfaces:**
- Produces: `struct LiveProcess: Equatable, Sendable { let pid: Int32; let cwd: String; let tty: String?; let ppid: Int32 }`
- Produces: `ProcessProbing.liveClaudeProcesses() -> [LiveProcess]` (new protocol requirement).
- Produces: `LibprocProcessProbe.tally(processes:) -> [String: Int]` (pure helper).
- Keeps: `ProcessProbing.liveClaudeCwdCounts() -> [String: Int]` (now a protocol extension default deriving from `liveClaudeProcesses()`), so `SessionScanner`/`RunningResolver` are unchanged.

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeMeterCoreTests/LiveProcessTallyTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct LiveProcessTallyTests {
    private func proc(_ pid: Int32, _ cwd: String, tty: String? = nil, ppid: Int32 = 1) -> LiveProcess {
        LiveProcess(pid: pid, cwd: cwd, tty: tty, ppid: ppid)
    }

    @Test func tallyGroupsByCwd() {
        let counts = LibprocProcessProbe.tally(processes: [
            proc(10, "/a"), proc(11, "/a"), proc(12, "/b"),
        ])
        #expect(counts == ["/a": 2, "/b": 1])
    }

    @Test func defaultCwdCountsDerivesFromProcesses() {
        struct Fake: ProcessProbing {
            func liveClaudeProcesses() -> [LiveProcess] {
                [LiveProcess(pid: 1, cwd: "/x", tty: "/dev/ttys001", ppid: 9),
                 LiveProcess(pid: 2, cwd: "/x", tty: "/dev/ttys002", ppid: 9)]
            }
        }
        #expect(Fake().liveClaudeCwdCounts() == ["/x": 2])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LiveProcessTallyTests`
Expected: FAIL — `LiveProcess` and `tally(processes:)` do not exist.

- [ ] **Step 3: Create the model**

Create `Sources/ClaudeMeterCore/Models/LiveProcess.swift`:

```swift
import Foundation

/// One live Claude Code CLI process as seen by the process probe.
///
/// `tty` is the controlling terminal device path (e.g. `/dev/ttys003`) used to
/// match the session to its iTerm2 tab; `ppid` is the parent PID used to walk up
/// to the owning terminal application.
public struct LiveProcess: Equatable, Sendable {
    public let pid: Int32
    public let cwd: String
    public let tty: String?
    public let ppid: Int32

    public init(pid: Int32, cwd: String, tty: String?, ppid: Int32) {
        self.pid = pid
        self.cwd = cwd
        self.tty = tty
        self.ppid = ppid
    }
}
```

- [ ] **Step 4: Extend the probe protocol + libproc impl**

In `Sources/ClaudeMeterCore/Services/ProcessProbe.swift`, replace the protocol and add the new reads. Change the protocol to require `liveClaudeProcesses()` and provide `liveClaudeCwdCounts()` as a default:

```swift
public protocol ProcessProbing: Sendable {
    /// Every live Claude Code CLI process with its pid, cwd, controlling tty, and parent pid.
    func liveClaudeProcesses() -> [LiveProcess]
}

public extension ProcessProbing {
    /// Working-directory path -> count of live `claude` processes whose cwd is that path.
    func liveClaudeCwdCounts() -> [String: Int] {
        LibprocProcessProbe.tally(processes: liveClaudeProcesses())
    }
}
```

Replace `LibprocProcessProbe`'s body so it builds `[LiveProcess]`. Keep `isClaudeCodeExecutable`, `allPids`, `executablePath`, `currentWorkingDirectory` as-is and add `parentPID` + `controllingTTY`:

```swift
public struct LibprocProcessProbe: ProcessProbing {
    public init() {}

    public func liveClaudeProcesses() -> [LiveProcess] {
        var result: [LiveProcess] = []
        for pid in Self.allPids() {
            guard let path = Self.executablePath(pid), Self.isClaudeCodeExecutable(path),
                  let cwd = Self.currentWorkingDirectory(pid) else { continue }
            result.append(LiveProcess(
                pid: pid, cwd: cwd,
                tty: Self.controllingTTY(pid),
                ppid: Self.parentPID(pid)
            ))
        }
        return result
    }

    /// Pure, separately-testable tally helper. Returns `[cwd: count]`.
    public static func tally(processes: [LiveProcess]) -> [String: Int] {
        processes.reduce(into: [String: Int]()) { counts, p in
            counts[p.cwd, default: 0] += 1
        }
    }

    public static func isClaudeCodeExecutable(_ path: String) -> Bool {
        guard !path.contains("ClaudeMeter") else { return false }
        return path.contains("/claude/versions/") || path.contains("/claude-code/")
    }

    /// Parent PID via `PROC_PIDTASKINFO` -> `pti_ppid`; 0 if unreadable.
    private static func parentPID(_ pid: pid_t) -> Int32 {
        var info = proc_bsdinfo()
        let code = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                                Int32(MemoryLayout<proc_bsdinfo>.size))
        guard code > 0 else { return 0 }
        return Int32(bitPattern: info.pbi_ppid)
    }

    /// Controlling tty device path (e.g. `/dev/ttys003`) via `PROC_PIDTBSDINFO`
    /// `e_tdev` -> `devname`, or `nil` if the process has no controlling tty.
    private static func controllingTTY(_ pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let code = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                                Int32(MemoryLayout<proc_bsdinfo>.size))
        guard code > 0 else { return nil }
        let dev = info.e_tdev
        guard dev != UInt32.max, dev != 0 else { return nil }
        guard let cName = devname(dev_t(dev), S_IFCHR) else { return nil }
        let name = String(cString: cName)
        return name.isEmpty ? nil : "/dev/\(name)"
    }
    ...
}
```

Note: `proc_bsdinfo` exposes both `pbi_ppid` and `e_tdev`, so one `PROC_PIDTBSDINFO` call can serve both; collapsing the two helpers into one fetch is an acceptable optimization, but keep them separate here for clarity unless the file nears 400 lines.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter LiveProcessTallyTests`
Expected: PASS (both tests).

- [ ] **Step 6: Run the full suite to confirm no regressions**

Run: `swift test`
Expected: PASS — existing `ProcessProbe`/`SessionScanner` tests still green (they only use `liveClaudeCwdCounts()`, now defaulted). If any existing fake implements `ProcessProbing` by defining `liveClaudeCwdCounts()` directly, update it to implement `liveClaudeProcesses()` instead.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeMeterCore/Models/LiveProcess.swift Sources/ClaudeMeterCore/Services/ProcessProbe.swift Tests/ClaudeMeterCoreTests/LiveProcessTallyTests.swift
git commit -m "feat(core): expose pid/cwd/tty/ppid per live claude process"
```

---

### Task 2: `CutoffDetector` — the safety-critical eligibility gate

**Files:**
- Create: `Sources/ClaudeMeterCore/Models/SessionEligibility.swift`
- Create: `Sources/ClaudeMeterCore/Services/CutoffDetector.swift`
- Test: `Tests/ClaudeMeterCoreTests/CutoffDetectorTests.swift`

**Interfaces:**
- Produces: `enum SessionEligibility: Equatable, Sendable { case eligibleCutoff, cleanlyFinished, awaitingUserInput, running, unknown }`
- Produces: `struct CutoffDetector: Sendable { init(); func classify(tailLines: [String], isRunning: Bool) -> SessionEligibility }`
- Consumes: nothing from other tasks. Parses raw JSONL lines (lenient) for the specific fields it needs.
- **Decision encoded:** the coordinator fires **only** on `.eligibleCutoff`. `.awaitingUserInput` is detected (last entry is a real user message with no following assistant reply) but is **not** auto-fired in v1 — it is reported for observability. This is intentionally conservative; revisit if needed.

**Detection signal (grounded in real transcripts):** A usage-limit cutoff is a synthetic assistant entry:
```json
{"type":"assistant","isApiErrorMessage":true,
 "message":{"model":"<synthetic>","stop_reason":"stop_sequence",
   "content":[{"type":"text","text":"You've hit your session limit · resets 4:30am (Europe/Bratislava)"}]}}
```
Rule: classify by the **last meaningful entry** in the tail (ignore non-conversational entry types: `ai-title`, `mode`, `attachment`, `summary`).
- last meaningful = assistant with `isApiErrorMessage == true` and `message.model == "<synthetic>"` and text contains "limit" → `.eligibleCutoff`
- `isRunning == true` → `.running` (overrides; never nudge a busy session)
- last meaningful = assistant with a normal model and `stop_reason == "end_turn"` → `.cleanlyFinished`
- last meaningful = assistant with `stop_reason == "tool_use"` (or any non-terminal stop) → `.running` (a turn is in flight)
- last meaningful = real `user` message (not a `[SYSTEM NOTIFICATION` / tool-result synthetic) with no later assistant → `.awaitingUserInput`
- otherwise → `.unknown`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeMeterCoreTests/CutoffDetectorTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct CutoffDetectorTests {
    private let detector = CutoffDetector()

    private let cutoffLine = #"{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"You've hit your session limit · resets 4:30am (Europe/Bratislava)"}]}}"#
    private let cleanLine = #"{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"All done — tests pass."}]}}"#
    private let toolUseLine = #"{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}]}}"#
    private let userLine = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"please refactor this"}]}}"#
    private let systemNotifLine = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[SYSTEM NOTIFICATION - NOT USER INPUT] background event"}]}}"#
    private let aiTitleLine = #"{"type":"ai-title"}"#
    private let modeLine = #"{"type":"mode"}"#

    @Test func cutoffWhenTailIsSyntheticLimit() {
        #expect(detector.classify(tailLines: [cleanLine, userLine, cutoffLine], isRunning: false) == .eligibleCutoff)
    }

    @Test func ignoresTrailingNonConversationalEntries() {
        #expect(detector.classify(tailLines: [cutoffLine, aiTitleLine, modeLine], isRunning: false) == .eligibleCutoff)
    }

    @Test func cleanFinishIsNotEligible() {
        #expect(detector.classify(tailLines: [userLine, cleanLine], isRunning: false) == .cleanlyFinished)
    }

    @Test func toolUseTailMeansRunning() {
        #expect(detector.classify(tailLines: [userLine, toolUseLine], isRunning: false) == .running)
    }

    @Test func isRunningOverridesCutoff() {
        #expect(detector.classify(tailLines: [cutoffLine], isRunning: true) == .running)
    }

    @Test func realUserPromptAwaitsInput() {
        #expect(detector.classify(tailLines: [cleanLine, userLine], isRunning: false) == .awaitingUserInput)
    }

    @Test func systemNotificationUserIsNotAwaitingInput() {
        // A [SYSTEM NOTIFICATION ...] user entry is not a real prompt.
        #expect(detector.classify(tailLines: [cleanLine, systemNotifLine], isRunning: false) == .cleanlyFinished)
    }

    @Test func emptyTailIsUnknown() {
        #expect(detector.classify(tailLines: [], isRunning: false) == .unknown)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CutoffDetectorTests`
Expected: FAIL — `SessionEligibility` / `CutoffDetector` undefined.

- [ ] **Step 3: Create the eligibility enum**

Create `Sources/ClaudeMeterCore/Models/SessionEligibility.swift`:

```swift
import Foundation

/// Whether an armed session should be nudged to continue at a quota refresh.
public enum SessionEligibility: Equatable, Sendable {
    /// Idle and stopped at the usage limit with work pending — fire `continue`.
    case eligibleCutoff
    /// Idle and cleanly finished (no pending work) — never fire; stays armed.
    case awaitingUserInput
    /// Cleanly finished — never fire.
    case cleanlyFinished
    /// A turn is in flight / process busy — never fire.
    case running
    /// Could not be determined — never fire.
    case unknown

    /// The only state the coordinator fires on in v1.
    public var shouldFire: Bool { self == .eligibleCutoff }
}
```

- [ ] **Step 4: Implement the detector**

Create `Sources/ClaudeMeterCore/Services/CutoffDetector.swift`:

```swift
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
                default: return .running   // tool_use, max_tokens, nil, etc. => in flight
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
            text: Self.extractText(message?["content"])
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter CutoffDetectorTests`
Expected: PASS (all 8 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeMeterCore/Models/SessionEligibility.swift Sources/ClaudeMeterCore/Services/CutoffDetector.swift Tests/ClaudeMeterCoreTests/CutoffDetectorTests.swift
git commit -m "feat(core): add CutoffDetector usage-limit eligibility gate"
```

---

### Task 3: `TerminalDetector` — owning terminal via parent-PID chain

**Files:**
- Create: `Sources/ClaudeMeterCore/Models/TerminalKind.swift`
- Create: `Sources/ClaudeMeterCore/Services/TerminalDetector.swift`
- Test: `Tests/ClaudeMeterCoreTests/TerminalDetectorTests.swift`

**Interfaces:**
- Produces: `enum TerminalKind: String, Equatable, Sendable, Codable { case iTerm2, appleTerminal, ghostty, wezterm, warp, vscode, unknown; var isDrivable: Bool; var displayName: String }`
- Produces: `struct TerminalDetector: Sendable { init(); func detect(startPID: Int32, executablePathForPID: (Int32) -> String?, parentPIDForPID: (Int32) -> Int32) -> TerminalKind }`
- Consumes: nothing. Injecting the two PID→info closures keeps it pure/testable (production passes libproc-backed closures).

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeMeterCoreTests/TerminalDetectorTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct TerminalDetectorTests {
    private let detector = TerminalDetector()

    /// Build closures over a synthetic process tree: pid -> (path, ppid).
    private func tree(_ nodes: [Int32: (String, Int32)])
        -> (paths: (Int32) -> String?, parents: (Int32) -> Int32) {
        ({ nodes[$0]?.0 }, { nodes[$0]?.1 ?? 0 })
    }

    @Test func findsITermThroughChain() {
        let t = tree([
            100: ("/Users/x/.local/share/claude/versions/2.1/claude", 90),
            90: ("/bin/zsh", 50),
            50: ("/Applications/iTerm.app/Contents/MacOS/iTerm2", 1),
        ])
        #expect(detector.detect(startPID: 100, executablePathForPID: t.paths, parentPIDForPID: t.parents) == .iTerm2)
    }

    @Test func findsAppleTerminal() {
        let t = tree([
            10: ("/claude/versions/x/claude", 9),
            9: ("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", 1),
        ])
        #expect(detector.detect(startPID: 10, executablePathForPID: t.paths, parentPIDForPID: t.parents) == .appleTerminal)
    }

    @Test func unknownWhenChainEndsAtLaunchd() {
        let t = tree([5: ("/claude/versions/x/claude", 1)])
        #expect(detector.detect(startPID: 5, executablePathForPID: t.paths, parentPIDForPID: t.parents) == .unknown)
    }

    @Test func iTermIsDrivableOthersAreNot() {
        #expect(TerminalKind.iTerm2.isDrivable)
        #expect(!TerminalKind.appleTerminal.isDrivable)
        #expect(!TerminalKind.unknown.isDrivable)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TerminalDetectorTests`
Expected: FAIL — types undefined.

- [ ] **Step 3: Create the enum**

Create `Sources/ClaudeMeterCore/Models/TerminalKind.swift`:

```swift
import Foundation

/// The terminal emulator that owns a Claude Code session's process.
public enum TerminalKind: String, Equatable, Sendable, Codable {
    case iTerm2, appleTerminal, ghostty, wezterm, warp, vscode, unknown

    /// Whether ClaudeMeter can drive this terminal in v1 (iTerm2 only).
    public var isDrivable: Bool { self == .iTerm2 }

    public var displayName: String {
        switch self {
        case .iTerm2: return "iTerm2"
        case .appleTerminal: return "Terminal"
        case .ghostty: return "Ghostty"
        case .wezterm: return "WezTerm"
        case .warp: return "Warp"
        case .vscode: return "VS Code"
        case .unknown: return "Terminal"
        }
    }
}
```

- [ ] **Step 4: Implement the detector**

Create `Sources/ClaudeMeterCore/Services/TerminalDetector.swift`:

```swift
import Foundation

/// Walks a process's parent-PID chain to the owning terminal emulator, matching
/// each ancestor's executable path against known terminal bundles. Pure: the
/// PID→path and PID→parent lookups are injected so it can be unit-tested over a
/// synthetic process tree.
public struct TerminalDetector: Sendable {
    public init() {}

    private static let maxDepth = 12

    public func detect(
        startPID: Int32,
        executablePathForPID: (Int32) -> String?,
        parentPIDForPID: (Int32) -> Int32
    ) -> TerminalKind {
        var pid = startPID
        var depth = 0
        while pid > 1, depth < Self.maxDepth {
            if let path = executablePathForPID(pid), let kind = Self.match(path) {
                return kind
            }
            pid = parentPIDForPID(pid)
            depth += 1
        }
        return .unknown
    }

    /// Match an executable path to a terminal kind, or `nil` if it isn't a terminal.
    static func match(_ path: String) -> TerminalKind? {
        if path.contains("/iTerm.app/") || path.hasSuffix("/iTerm2") { return .iTerm2 }
        if path.contains("/Terminal.app/") { return .appleTerminal }
        if path.contains("/Ghostty.app/") { return .ghostty }
        if path.contains("/WezTerm.app/") || path.contains("wezterm") { return .wezterm }
        if path.contains("/Warp.app/") { return .warp }
        if path.contains("/Code.app/") || path.contains("Visual Studio Code") { return .vscode }
        return nil
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter TerminalDetectorTests`
Expected: PASS (all 4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeMeterCore/Models/TerminalKind.swift Sources/ClaudeMeterCore/Services/TerminalDetector.swift Tests/ClaudeMeterCoreTests/TerminalDetectorTests.swift
git commit -m "feat(core): detect owning terminal via parent-pid chain"
```

---

### Task 4: `ArmedSessionsStore` + `WidgetCommand` — persistence & command channel

**Files:**
- Create: `Sources/ClaudeMeterCore/Models/WidgetCommand.swift`
- Create: `Sources/ClaudeMeterCore/Services/ArmedSessionsStore.swift`
- Test: `Tests/ClaudeMeterCoreTests/ArmedSessionsStoreTests.swift`
- Test: `Tests/ClaudeMeterCoreTests/WidgetCommandTests.swift`

**Interfaces:**
- Produces: `struct WidgetCommand: Equatable, Sendable, Codable { enum Action: String, Codable { case arm, disarm }; let action: Action; let sessionID: String }`
- Produces: `struct WidgetCommandBatch: Equatable, Sendable, Codable { var commands: [WidgetCommand] }`
- Produces: `struct ArmedSessionsStore: Sendable` with:
  - `func encode(_ ids: Set<String>) throws -> Data` / `func decode(_ data: Data) throws -> Set<String>`
  - `func write(_ ids: Set<String>, to url: URL) throws` / `func read(from url: URL) -> Set<String>`
  - `func appendCommand(_ command: WidgetCommand, to url: URL) throws` / `func drainCommands(at url: URL) -> [WidgetCommand]` (reads then deletes the file atomically).
- Consumes: nothing.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeMeterCoreTests/ArmedSessionsStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct ArmedSessionsStoreTests {
    private let store = ArmedSessionsStore()

    private func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("armedtests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    @Test func roundTripsArmedSet() throws {
        let url = tmp("armed.json")
        try store.write(["a", "b", "c"], to: url)
        #expect(store.read(from: url) == ["a", "b", "c"])
    }

    @Test func readsEmptyWhenMissing() {
        #expect(store.read(from: tmp("none.json")).isEmpty)
    }

    @Test func appendAndDrainCommands() throws {
        let url = tmp("commands.json")
        try store.appendCommand(WidgetCommand(action: .arm, sessionID: "x"), to: url)
        try store.appendCommand(WidgetCommand(action: .disarm, sessionID: "y"), to: url)
        let drained = store.drainCommands(at: url)
        #expect(drained == [WidgetCommand(action: .arm, sessionID: "x"),
                            WidgetCommand(action: .disarm, sessionID: "y")])
        // Draining removes the file, so a second drain is empty.
        #expect(store.drainCommands(at: url).isEmpty)
    }
}
```

Create `Tests/ClaudeMeterCoreTests/WidgetCommandTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct WidgetCommandTests {
    @Test func codableRoundTrip() throws {
        let batch = WidgetCommandBatch(commands: [
            WidgetCommand(action: .disarm, sessionID: "abc"),
        ])
        let data = try JSONEncoder().encode(batch)
        let back = try JSONDecoder().decode(WidgetCommandBatch.self, from: data)
        #expect(back == batch)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ArmedSessionsStoreTests` then `swift test --filter WidgetCommandTests`
Expected: FAIL — types undefined.

- [ ] **Step 3: Create `WidgetCommand`**

Create `Sources/ClaudeMeterCore/Models/WidgetCommand.swift`:

```swift
import Foundation

/// A command the widget asks the app to perform. The sandboxed widget cannot
/// write the app's armed store directly, so it appends a command to a file in
/// its own container that the (non-sandboxed) app drains and applies.
public struct WidgetCommand: Equatable, Sendable, Codable {
    public enum Action: String, Equatable, Sendable, Codable {
        case arm
        case disarm
    }

    public let action: Action
    public let sessionID: String

    public init(action: Action, sessionID: String) {
        self.action = action
        self.sessionID = sessionID
    }
}

/// A persisted list of pending widget commands.
public struct WidgetCommandBatch: Equatable, Sendable, Codable {
    public var commands: [WidgetCommand]
    public init(commands: [WidgetCommand]) { self.commands = commands }
}
```

- [ ] **Step 4: Create `ArmedSessionsStore`**

Create `Sources/ClaudeMeterCore/Services/ArmedSessionsStore.swift`:

```swift
import Foundation

/// Persists the set of armed session UUIDs and shuttles widget commands.
/// Mirrors `SnapshotStore`: a small `Codable` payload written atomically.
public struct ArmedSessionsStore: Sendable {
    private struct Container: Codable { let sessionIDs: [String] }

    public init() {}

    // MARK: Armed set

    public func encode(_ ids: Set<String>) throws -> Data {
        try JSONEncoder().encode(Container(sessionIDs: ids.sorted()))
    }

    public func decode(_ data: Data) throws -> Set<String> {
        Set(try JSONDecoder().decode(Container.self, from: data).sessionIDs)
    }

    public func write(_ ids: Set<String>, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(ids).write(to: url, options: .atomic)
    }

    public func read(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decode(data)) ?? []
    }

    // MARK: Widget command queue

    public func appendCommand(_ command: WidgetCommand, to url: URL) throws {
        var batch = readBatch(at: url)
        batch.commands.append(command)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(batch).write(to: url, options: .atomic)
    }

    /// Reads all pending commands and removes the file (best-effort).
    public func drainCommands(at url: URL) -> [WidgetCommand] {
        let batch = readBatch(at: url)
        try? FileManager.default.removeItem(at: url)
        return batch.commands
    }

    private func readBatch(at url: URL) -> WidgetCommandBatch {
        guard let data = try? Data(contentsOf: url),
              let batch = try? JSONDecoder().decode(WidgetCommandBatch.self, from: data)
        else { return WidgetCommandBatch(commands: []) }
        return batch
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ArmedSessionsStoreTests` then `swift test --filter WidgetCommandTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeMeterCore/Models/WidgetCommand.swift Sources/ClaudeMeterCore/Services/ArmedSessionsStore.swift Tests/ClaudeMeterCoreTests/ArmedSessionsStoreTests.swift Tests/ClaudeMeterCoreTests/WidgetCommandTests.swift
git commit -m "feat(core): persist armed sessions + widget command channel"
```

---

### Task 5: Carry armed + armable IDs in `SessionSnapshot`

**Files:**
- Modify: `Sources/ClaudeMeterCore/Models/SessionSnapshot.swift`
- Test: `Tests/ClaudeMeterCoreTests/SessionSnapshotArmedTests.swift`

**Interfaces:**
- Produces: `SessionSnapshot.armedSessionIDs: [String]` and `SessionSnapshot.armableSessionIDs: [String]` (new stored properties; Codable with empty defaults for back-compat). `armableSessionIDs` = the running iTerm2 sessions the widget may offer an **arm** button for.
- Produces: updated `SessionSnapshot.init(...)` with `armedSessionIDs: [String] = []`, `armableSessionIDs: [String] = []`, and `SessionSnapshot.make(..., armedSessionIDs: [String] = [], armableSessionIDs: [String] = [])`.
- Consumes: existing `SessionSnapshot` from Task-0 codebase.

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeMeterCoreTests/SessionSnapshotArmedTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite struct SessionSnapshotArmedTests {
    private func session(_ id: String) -> SessionUsage {
        SessionUsage(id: id, origin: .cli, projectPath: "/p/\(id)", models: ["m"],
                     tokens: TokenBreakdown(input: 1), messageCount: 1,
                     firstActivity: Date(timeIntervalSince1970: 0),
                     lastActivity: Date(timeIntervalSince1970: 0), burnRate: 0, running: .running)
    }

    @Test func makeCarriesArmedAndArmableIDs() {
        let snap = SessionSnapshot.make(
            from: [session("a"), session("b")], now: Date(timeIntervalSince1970: 0),
            armedSessionIDs: ["a"], armableSessionIDs: ["a", "b"])
        #expect(snap.armedSessionIDs == ["a"])
        #expect(snap.armableSessionIDs == ["a", "b"])
    }

    @Test func decodesLegacySnapshotWithoutNewFields() throws {
        // A snapshot encoded before these fields existed must still decode.
        let legacy = #"{"generatedAt":0,"sessions":[],"totalTokens":0,"runningCount":0}"#
        let data = Data(legacy.utf8)
        let decoder = JSONDecoder()
        let snap = try decoder.decode(SessionSnapshot.self, from: data)
        #expect(snap.armedSessionIDs.isEmpty)
        #expect(snap.armableSessionIDs.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionSnapshotArmedTests`
Expected: FAIL — `armedSessionIDs` unknown / `make` has no such parameter.

- [ ] **Step 3: Add the field**

Edit `Sources/ClaudeMeterCore/Models/SessionSnapshot.swift`. Add the stored property, extend `init`, add a decoding fallback, and thread it through `make`:

```swift
public struct SessionSnapshot: Equatable, Sendable, Codable {
    public let generatedAt: Date
    public let sessions: [SessionUsage]
    public let totalTokens: Int
    public let runningCount: Int
    public let armedSessionIDs: [String]
    public let armableSessionIDs: [String]

    public init(generatedAt: Date, sessions: [SessionUsage], totalTokens: Int,
                runningCount: Int, armedSessionIDs: [String] = [], armableSessionIDs: [String] = []) {
        self.generatedAt = generatedAt
        self.sessions = sessions
        self.totalTokens = totalTokens
        self.runningCount = runningCount
        self.armedSessionIDs = armedSessionIDs
        self.armableSessionIDs = armableSessionIDs
    }

    // Custom decode so snapshots written before these fields existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        sessions = try c.decode([SessionUsage].self, forKey: .sessions)
        totalTokens = try c.decode(Int.self, forKey: .totalTokens)
        runningCount = try c.decode(Int.self, forKey: .runningCount)
        armedSessionIDs = try c.decodeIfPresent([String].self, forKey: .armedSessionIDs) ?? []
        armableSessionIDs = try c.decodeIfPresent([String].self, forKey: .armableSessionIDs) ?? []
    }

    public static func make(
        from sessions: [SessionUsage],
        now: Date,
        limit: Int = 5,
        runningOnly: Bool = false,
        armedSessionIDs: [String] = [],
        armableSessionIDs: [String] = []
    ) -> SessionSnapshot {
        let pool = runningOnly ? sessions.filter { $0.running == .running } : sessions
        let ranked = pool.sorted { $0.totalTokens > $1.totalTokens }
        return SessionSnapshot(
            generatedAt: now,
            sessions: Array(ranked.prefix(limit)),
            totalTokens: sessions.reduce(0) { $0 + $1.totalTokens },
            runningCount: sessions.filter { $0.running == .running }.count,
            armedSessionIDs: armedSessionIDs,
            armableSessionIDs: armableSessionIDs
        )
    }
}
```

Note: defining `init(from:)` requires explicit `CodingKeys`; add `private enum CodingKeys: String, CodingKey { case generatedAt, sessions, totalTokens, runningCount, armedSessionIDs, armableSessionIDs }`. The synthesized `encode(to:)` remains valid.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SessionSnapshotArmedTests`
Expected: PASS.

- [ ] **Step 5: Run the full suite (existing snapshot tests must stay green)**

Run: `swift test`
Expected: PASS — `SessionSnapshotTests` / `SnapshotStoreTests` unaffected (new field defaults to empty).

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeMeterCore/Models/SessionSnapshot.swift Tests/ClaudeMeterCoreTests/SessionSnapshotArmedTests.swift
git commit -m "feat(core): carry armed + armable session ids in SessionSnapshot"
```

---

## Phase B — App services (system integration)

### Task 6: `SleepInhibitor` — IOKit power assertion

**Files:**
- Create: `Sources/ClaudeMeter/Support/SleepInhibitor.swift`

**Interfaces:**
- Produces: `@MainActor final class SleepInhibitor { func update(active: Bool); var isHolding: Bool { get } }` — idempotent; holds one `PreventUserIdleSystemSleep` assertion while `active`.
- Consumes: nothing.

This is App-target, IOKit-backed, and verified by build + manual check (no unit test — it touches the live power-management subsystem).

- [ ] **Step 1: Create the inhibitor**

Create `Sources/ClaudeMeter/Support/SleepInhibitor.swift`:

```swift
import Foundation
import IOKit.pwr_mgt
import os

/// Holds a single IOKit power assertion that keeps the Mac awake while at least
/// one session is armed. Idempotent: repeated `update(active:)` calls with the
/// same value are no-ops.
@MainActor
final class SleepInhibitor {
    private var assertionID: IOPMAssertionID = 0
    private var holding = false
    private let log = Logger(subsystem: "com.jakubzak.claudemeter", category: "sleep")

    var isHolding: Bool { holding }

    func update(active: Bool) {
        if active { acquire() } else { release() }
    }

    private func acquire() {
        guard !holding else { return }
        var id: IOPMAssertionID = 0
        let reason = "ClaudeMeter auto-resume armed" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason, &id)
        guard result == kIOReturnSuccess else {
            log.error("failed to create power assertion: \(result)")
            return
        }
        assertionID = id
        holding = true
    }

    private func release() {
        guard holding else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        holding = false
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds without errors. (IOKit links automatically on macOS.)

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeMeter/Support/SleepInhibitor.swift
git commit -m "feat(app): add IOKit SleepInhibitor for armed sessions"
```

---

### Task 7: `TerminalResumeDriver` protocol + `ITermDriver`

**Files:**
- Create: `Sources/ClaudeMeter/Support/TerminalResumeDriver.swift`
- Create: `Sources/ClaudeMeter/Support/ITermDriver.swift`

**Interfaces:**
- Produces: `struct ResumeTarget { let sessionID: String; let tty: String; let continueText: String }`
- Produces: `protocol TerminalResumeDriver { func resume(_ target: ResumeTarget) throws }`
- Produces: `enum ResumeError: Error { case missingTTY, terminalNotRunning, sessionNotFound, scriptFailed(String) }`
- Produces: `struct ITermDriver: TerminalResumeDriver` — finds the iTerm2 session whose `tty` matches and runs `write text`.
- Consumes: `ResumeTarget` is constructed by `AutoResumeCoordinator` (Task 9) after PID verification.

The AppleScript path is intentionally thin (per spec: most logic lives in tested units; this is verified manually against a real iTerm2).

- [ ] **Step 1: Create the protocol + errors**

Create `Sources/ClaudeMeter/Support/TerminalResumeDriver.swift`:

```swift
import Foundation

/// What the driver needs to type `continue` into the right tab.
struct ResumeTarget: Equatable {
    let sessionID: String
    /// Controlling tty device path, e.g. "/dev/ttys003".
    let tty: String
    /// Text to send (default "continue"); the driver appends a newline.
    let continueText: String
}

enum ResumeError: Error, Equatable {
    case missingTTY
    case terminalNotRunning
    case sessionNotFound
    case scriptFailed(String)
}

/// Types the continue text into a session's live terminal tab. Mockable.
protocol TerminalResumeDriver {
    func resume(_ target: ResumeTarget) throws
}
```

- [ ] **Step 2: Create the iTerm2 driver**

Create `Sources/ClaudeMeter/Support/ITermDriver.swift`:

```swift
import Foundation
import os

/// Drives iTerm2 via AppleScript: locate the session whose `tty` matches the
/// target and `write text` the continue string into exactly that session. Never
/// activates iTerm2 or steals focus. Throws if iTerm2 isn't running or no
/// session has the tty (the coordinator turns that into a skip + notification).
struct ITermDriver: TerminalResumeDriver {
    private let log = Logger(subsystem: "com.jakubzak.claudemeter", category: "iterm")

    func resume(_ target: ResumeTarget) throws {
        guard !target.tty.isEmpty else { throw ResumeError.missingTTY }

        // AppleScript: only proceed if iTerm2 is already running; find the
        // session with the matching tty and write the text. Set a boolean we can
        // read back to distinguish "session not found" from success.
        let escapedText = target.continueText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "System Events"
            if not (exists process "iTerm2") then return "NOT_RUNNING"
        end tell
        set foundSession to false
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (tty of s) is "\(target.tty)" then
                            tell s to write text "\(escapedText)"
                            set foundSession to true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        if foundSession then
            return "OK"
        else
            return "NOT_FOUND"
        end if
        """

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw ResumeError.scriptFailed("could not compile AppleScript")
        }
        let output = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "\(errorInfo)"
            log.error("iTerm AppleScript error: \(message, privacy: .public)")
            throw ResumeError.scriptFailed(message)
        }
        switch output.stringValue {
        case "OK": return
        case "NOT_RUNNING": throw ResumeError.terminalNotRunning
        default: throw ResumeError.sessionNotFound
        }
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds without errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeMeter/Support/TerminalResumeDriver.swift Sources/ClaudeMeter/Support/ITermDriver.swift
git commit -m "feat(app): add TerminalResumeDriver protocol + iTerm2 driver"
```

---

### Task 8: `SessionProcessIndex` — map session UUID → unique live process

**Files:**
- Create: `Sources/ClaudeMeter/Support/SessionProcessIndex.swift`

**Interfaces:**
- Produces: `struct SessionProcessIndex { init(processes: [LiveProcess]); func process(forCwd cwd: String) -> LiveProcess? }` — returns a `LiveProcess` only when **exactly one** live claude process has that cwd (ambiguous → `nil`, so the coordinator safely skips).
- Produces: `func terminalKind(forCwd cwd: String, detector: TerminalDetector, paths: (Int32) -> String?, parents: (Int32) -> Int32) -> TerminalKind`
- Consumes: `LiveProcess` (Task 1), `TerminalDetector` (Task 3).

This is App-target glue but pure enough to deserve a small test; keep it App-side since it's only used by the coordinator. Verified via the coordinator's behavior and a focused inline check.

- [ ] **Step 1: Create the index**

Create `Sources/ClaudeMeter/Support/SessionProcessIndex.swift`:

```swift
import Foundation
import ClaudeMeterCore

/// Correlates a session (identified by its project cwd) to the single live
/// claude process in that directory. If two or more claude processes share a
/// cwd, the match is ambiguous and we return `nil` rather than risk typing into
/// the wrong tab.
struct SessionProcessIndex {
    private let byCwd: [String: [LiveProcess]]

    init(processes: [LiveProcess]) {
        self.byCwd = Dictionary(grouping: processes, by: { $0.cwd })
    }

    func process(forCwd cwd: String) -> LiveProcess? {
        guard let matches = byCwd[cwd], matches.count == 1 else { return nil }
        return matches[0]
    }

    func terminalKind(
        forCwd cwd: String,
        detector: TerminalDetector,
        paths: @escaping (Int32) -> String?,
        parents: @escaping (Int32) -> Int32
    ) -> TerminalKind {
        guard let proc = process(forCwd: cwd) else { return .unknown }
        return detector.detect(startPID: proc.pid, executablePathForPID: paths, parentPIDForPID: parents)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds without errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeMeter/Support/SessionProcessIndex.swift
git commit -m "feat(app): correlate session cwd to unique live process"
```

---

### Task 9: `ArmedSessions` store (app-side observable)

**Files:**
- Create: `Sources/ClaudeMeter/App/ArmedSessions.swift`

**Interfaces:**
- Produces: `@MainActor final class ArmedSessions: ObservableObject` with:
  - `@Published private(set) var armed: Set<String>`
  - `func isArmed(_ id: String) -> Bool`
  - `func setArmed(_ id: String, _ value: Bool)` (persists)
  - `func disarm(_ id: String)` / `func disarmAll()`
  - `var count: Int`
  - static URLs: `armedURL()` (App Support) and `commandInboxURL()` (widget container).
  - `func drainWidgetCommands(isArmable:)` — applies pending **arm and disarm** commands from the widget; arm requests are honored only when `isArmable(id)` is true (re-validation, so a stale widget can't arm a non-iTerm2 session).
- Consumes: `ArmedSessionsStore`, `WidgetCommand` (Task 4); `SessionMonitor.widgetBundleID` for the container path.

- [ ] **Step 1: Create the class**

Create `Sources/ClaudeMeter/App/ArmedSessions.swift`:

```swift
import Foundation
import Combine
import ClaudeMeterCore

/// The set of armed session UUIDs, persisted to Application Support and mirrored
/// from widget-issued disarm commands. The single source of truth in the app.
@MainActor
final class ArmedSessions: ObservableObject {
    @Published private(set) var armed: Set<String> = []

    private let store = ArmedSessionsStore()
    private let armedURL: URL
    private let commandURL: URL

    init(armedURL: URL = ArmedSessions.defaultArmedURL(),
         commandURL: URL = ArmedSessions.commandInboxURL()) {
        self.armedURL = armedURL
        self.commandURL = commandURL
        self.armed = store.read(from: armedURL)
    }

    var count: Int { armed.count }
    func isArmed(_ id: String) -> Bool { armed.contains(id) }

    func setArmed(_ id: String, _ value: Bool) {
        if value { armed.insert(id) } else { armed.remove(id) }
        persist()
    }

    func disarm(_ id: String) { setArmed(id, false) }

    func disarmAll() {
        guard !armed.isEmpty else { return }
        armed.removeAll()
        persist()
    }

    /// Apply any arm/disarm requests the widget queued, returning whether anything
    /// changed. Arm requests are honored only for sessions that are still armable
    /// (iTerm2 + running) per `isArmable`, re-validated here so a stale widget
    /// cannot arm an unsupported session.
    @discardableResult
    func drainWidgetCommands(isArmable: (String) -> Bool) -> Bool {
        let commands = store.drainCommands(at: commandURL)
        guard !commands.isEmpty else { return false }
        var changed = false
        for command in commands {
            switch command.action {
            case .disarm:
                if armed.remove(command.sessionID) != nil { changed = true }
            case .arm:
                if isArmable(command.sessionID), armed.insert(command.sessionID).inserted { changed = true }
            }
        }
        if changed { persist() }
        return changed
    }

    private func persist() { try? store.write(armed, to: armedURL) }

    // MARK: URLs

    static func defaultArmedURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeMeter", isDirectory: true)
            .appendingPathComponent("armed-sessions.json")
    }

    /// The widget writes disarm requests into its own container; the app reads them here.
    static func commandInboxURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(SessionMonitor.widgetBundleID)/Data/Documents",
                                    isDirectory: true)
            .appendingPathComponent("widget-commands.json")
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds without errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeMeter/App/ArmedSessions.swift
git commit -m "feat(app): observable armed-sessions store with widget command drain"
```

---

### Task 10: `AutoResumeCoordinator` — orchestration

**Files:**
- Create: `Sources/ClaudeMeter/App/AutoResumeCoordinator.swift`

**Interfaces:**
- Produces: `@MainActor final class AutoResumeCoordinator` with:
  - `init(armed: ArmedSessions, settings: Settings, driver: TerminalResumeDriver = ITermDriver(), staggerSeconds: Double = 1.5, notify: @escaping (String) -> Void)`
  - `func handleSnapshot(usage: UsageSnapshot, sessions: [SessionUsage], processes: [LiveProcess], transcriptTail: (String) -> [String], paths: @escaping (Int32) -> String?, parents: @escaping (Int32) -> Int32)` — called by `SessionMonitor`/`AppDelegate` each cycle. Detects a quota-refresh crossing using its own remembered utilization + `UsageStats.didRefill`, and fires eligible armed sessions.
  - `func terminalKind(forSessionCwd:)`-style helper exposed for the UI (Task 13) so rows know if they're drivable.
- Consumes: `ArmedSessions` (9), `Settings` (11), `TerminalResumeDriver`/`ResumeTarget` (7), `SessionProcessIndex` (8), `CutoffDetector` (2), `TerminalDetector` (3), `UsageStats.didRefill` (existing), `LiveProcess` (1).

**Firing rule (decided: stagger, no cap):** on a refresh crossing, for each armed session that is eligible (`CutoffDetector.classify == .eligibleCutoff`), drivable (iTerm2), and uniquely mapped to a live process whose pid/cwd still verify, dispatch `driver.resume` spaced by `staggerSeconds`. Track `firedThisCrossing` so a single crossing never double-fires; clear it once utilization climbs back up (next session started).

- [ ] **Step 1: Create the coordinator**

Create `Sources/ClaudeMeter/App/AutoResumeCoordinator.swift`:

```swift
import Foundation
import ClaudeMeterCore
import os

/// Watches for quota refreshes and, for each armed + eligible + iTerm2 session,
/// types `continue` into its tab with a small stagger. Pure decision inputs are
/// passed in by the caller so this stays unit-test friendly via a mock driver.
@MainActor
final class AutoResumeCoordinator {
    private let armed: ArmedSessions
    private let settings: Settings
    private let driver: TerminalResumeDriver
    private let detector = CutoffDetector()
    private let terminalDetector = TerminalDetector()
    private let staggerSeconds: Double
    private let notify: (String) -> Void
    private let log = Logger(subsystem: "com.jakubzak.claudemeter", category: "autoresume")

    /// Last seen 5-hour utilization, to detect a refill crossing.
    private var lastUtilization: Double?
    /// Sessions already fired during the current low-utilization window.
    private var firedThisCrossing: Set<String> = []

    init(armed: ArmedSessions,
         settings: Settings,
         driver: TerminalResumeDriver = ITermDriver(),
         staggerSeconds: Double = 1.5,
         notify: @escaping (String) -> Void) {
        self.armed = armed
        self.settings = settings
        self.driver = driver
        self.staggerSeconds = staggerSeconds
        self.notify = notify
    }

    /// Resolve the owning terminal for a session's cwd (for the UI's arm toggle).
    func terminalKind(forCwd cwd: String,
                      processes: [LiveProcess],
                      paths: @escaping (Int32) -> String?,
                      parents: @escaping (Int32) -> Int32) -> TerminalKind {
        SessionProcessIndex(processes: processes)
            .terminalKind(forCwd: cwd, detector: terminalDetector, paths: paths, parents: parents)
    }

    func handleSnapshot(
        usage: UsageSnapshot?,
        sessions: [SessionUsage],
        processes: [LiveProcess],
        transcriptTail: (String) -> [String],
        paths: @escaping (Int32) -> String?,
        parents: @escaping (Int32) -> Int32
    ) {
        guard settings.autoResumeEnabled else { return }
        guard let bucket = usage?.fiveHour else { return }
        let current = bucket.utilization
        defer { lastUtilization = current }

        // A refill: utilization dropped meaningfully since last cycle.
        let refilled = UsageStats.didRefill(
            previousUtilization: lastUtilization, currentUtilization: current)
        if !refilled {
            // Once the window is being used again, allow the next crossing to fire.
            if let last = lastUtilization, current > last { firedThisCrossing.removeAll() }
            return
        }

        firedThisCrossing.removeAll()
        let index = SessionProcessIndex(processes: processes)
        let continueText = settings.normalizedContinueText
        var delay = 0.0

        for session in sessions where armed.isArmed(session.id) {
            guard !firedThisCrossing.contains(session.id) else { continue }

            // Map session -> unique live process by cwd.
            guard let proc = index.process(forCwd: session.projectPath), let tty = proc.tty else {
                notify("Skipped \(session.projectName): no unique live terminal found.")
                continue
            }
            // Must be iTerm2.
            let kind = terminalDetector.detect(startPID: proc.pid, executablePathForPID: paths, parentPIDForPID: parents)
            guard kind.isDrivable else {
                notify("Skipped \(session.projectName): \(kind.displayName) not supported yet.")
                continue
            }
            // Eligibility gate over the transcript tail. The live process means
            // "alive", but we pass isRunning=false because resolver-running is
            // about token activity; the tail tells us if a turn is in flight.
            let eligibility = detector.classify(tailLines: transcriptTail(session.id), isRunning: false)
            guard eligibility.shouldFire else { continue }

            let target = ResumeTarget(sessionID: session.id, tty: tty, continueText: continueText)
            firedThisCrossing.insert(session.id)
            scheduleResume(target, after: delay, projectName: session.projectName)
            delay += staggerSeconds
        }
    }

    private func scheduleResume(_ target: ResumeTarget, after delay: Double, projectName: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            do {
                try self.driver.resume(target)
                self.log.log("resumed \(projectName, privacy: .public)")
            } catch {
                self.notify("Couldn't resume \(projectName): \(String(describing: error))")
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds (depends on `Settings.autoResumeEnabled` / `normalizedContinueText` from Task 11 — if building this task first, temporarily reference `settings.notificationsEnabled` then revert; recommended order is Task 11 before Task 10, see note below).

> **Ordering note:** implement **Task 11 (Settings)** before this task so `settings.autoResumeEnabled` and `settings.normalizedContinueText` exist. The plan lists Task 10 here for narrative cohesion; execute 11 first.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeMeter/App/AutoResumeCoordinator.swift
git commit -m "feat(app): AutoResumeCoordinator fires eligible armed sessions on refill"
```

---

## Phase C — Settings & UI

### Task 11: Settings — feature toggle + continue text

**Files:**
- Modify: `Sources/ClaudeMeter/Support/Settings.swift`
- Modify: `Sources/ClaudeMeter/Views/SettingsView.swift`

**Interfaces:**
- Produces: `Settings.autoResumeEnabled: Bool` (default `false`), `Settings.autoResumeContinueText: String` (default `"continue"`), `Settings.normalizedContinueText: String` (trimmed; falls back to `"continue"` when blank).
- Consumes: existing `Settings` UserDefaults pattern.

- [ ] **Step 1: Add the properties to `Settings`**

In `Sources/ClaudeMeter/Support/Settings.swift`, add published properties with `didSet` persistence, init reads, keys, and the normalized helper. Insert alongside the existing properties:

```swift
    @Published var autoResumeEnabled: Bool {
        didSet { defaults.set(autoResumeEnabled, forKey: Keys.autoResumeEnabled) }
    }
    @Published var autoResumeContinueText: String {
        didSet { defaults.set(autoResumeContinueText, forKey: Keys.autoResumeContinueText) }
    }

    /// Continue text to type, trimmed; defaults to "continue" when blank.
    var normalizedContinueText: String {
        let trimmed = autoResumeContinueText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "continue" : trimmed
    }
```

In `init(defaults:)` add:

```swift
        self.autoResumeEnabled = defaults.object(forKey: Keys.autoResumeEnabled) as? Bool ?? false
        self.autoResumeContinueText = defaults.string(forKey: Keys.autoResumeContinueText) ?? "continue"
```

In `enum Keys` add:

```swift
        static let autoResumeEnabled = "autoResumeEnabled"
        static let autoResumeContinueText = "autoResumeContinueText"
```

- [ ] **Step 2: Add the Settings UI section**

In `Sources/ClaudeMeter/Views/SettingsView.swift`, add a new `Section` (after "Notifications"):

```swift
            Section("Overnight Auto-Resume") {
                Toggle("Auto-resume armed sessions on quota refresh", isOn: $settings.autoResumeEnabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continue text").font(.caption).foregroundStyle(.secondary)
                    TextField("continue", text: $settings.autoResumeContinueText)
                }
                Text("Arms are chosen per session in the Sessions window. Only iTerm2 sessions that were cut off by the usage limit are nudged. Controlling iTerm2 requires Automation permission (System Settings → Privacy & Security → Automation).")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds without errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeMeter/Support/Settings.swift Sources/ClaudeMeter/Views/SettingsView.swift
git commit -m "feat(app): settings for auto-resume toggle + continue text"
```

---

### Task 12: Wire coordinator + sleep inhibitor + armed store into `SessionMonitor` and `AppDelegate`

**Files:**
- Modify: `Sources/ClaudeMeter/App/SessionMonitor.swift`
- Modify: `Sources/ClaudeMeter/App/AppDelegate.swift`

**Interfaces:**
- Produces: `SessionMonitor.latestProcesses: [LiveProcess]` (published) and snapshot built with `armedSessionIDs`; a hook the delegate calls each cycle.
- Produces: `SessionMonitor` reads the transcript tail for a session id via a small helper `tailLines(forSessionID:maxLines:)`.
- Consumes: `ArmedSessions` (9), `AutoResumeCoordinator` (10), `SleepInhibitor` (6), `UsageStore` (existing), `LibprocProcessProbe.liveClaudeProcesses()` (1).

Because `SessionScanner` only returns `[cwd:count]`, the monitor additionally probes `liveClaudeProcesses()` directly (cheap) to obtain pid/tty/ppid and to feed armed IDs into the published snapshot.

- [ ] **Step 1: Extend `SessionMonitor` to expose processes + armed IDs**

In `Sources/ClaudeMeter/App/SessionMonitor.swift`:

Add stored deps and published processes near the top of the class:

```swift
    @Published private(set) var latestProcesses: [LiveProcess] = []

    /// Set by AppDelegate so the published snapshot can mark armed sessions and
    /// the post-scan hook can drive auto-resume.
    var armedIDsProvider: (() -> [String])?
    var onScan: ((UsageContextInputs) -> Void)?
    private let directProbe = LibprocProcessProbe()
    private let terminalDetectorForArmable = TerminalDetector()
```

Add a helper that computes which sessions are **armable** (uniquely-mapped iTerm2 + running), reused for both the published snapshot and arm re-validation:

```swift
    /// Session IDs that may be armed: running, mapped to exactly one live process,
    /// whose owning terminal is iTerm2.
    func armableSessionIDs(sessions: [SessionUsage], processes: [LiveProcess]) -> [String] {
        let index = SessionProcessIndex(processes: processes)
        return sessions.compactMap { session in
            guard session.running == .running, let proc = index.process(forCwd: session.projectPath)
            else { return nil }
            let kind = terminalDetectorForArmable.detect(
                startPID: proc.pid,
                executablePathForPID: { LibprocProcessProbe.executablePathForPID($0) },
                parentPIDForPID: { LibprocProcessProbe.parentPIDForPID($0) })
            return kind.isDrivable ? session.id : nil
        }
    }
```

Add a small inputs struct (App-side, top of file under imports):

```swift
/// Inputs the AppDelegate forwards to the AutoResumeCoordinator after each scan.
struct UsageContextInputs {
    let sessions: [SessionUsage]
    let processes: [LiveProcess]
}
```

Change `refresh()` to probe processes, fold armed IDs into the published snapshot, and call the hook:

```swift
    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let result = await scanner.scan(now: Date())
        let processes = directProbe.liveClaudeProcesses()
        let armedIDs = armedIDsProvider?() ?? []

        sessions = result.sessions
        latestProcesses = processes
        let armable = armableSessionIDs(sessions: result.sessions, processes: processes)
        // Rebuild the snapshot carrying armed + armable IDs (running-only, like before).
        let snap = SessionSnapshot.make(
            from: result.sessions, now: result.snapshot.generatedAt,
            limit: 12, runningOnly: true, armedSessionIDs: armedIDs, armableSessionIDs: armable)
        snapshot = snap
        lastUpdated = snap.generatedAt
        publish(snap)

        onScan?(UsageContextInputs(sessions: result.sessions, processes: processes))
    }
```

Add the tail reader (used by the coordinator) and libproc closures as nonisolated statics:

```swift
    /// Last `maxLines` lines of a session's transcript, for the cutoff gate.
    nonisolated static func tailLines(forSessionID id: String, maxLines: Int = 40) -> [String] {
        let roots = TranscriptSource().scanRoots()   // existing API on TranscriptSource
        for root in roots {
            if let url = Self.findTranscript(id: id, under: root) {
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
                let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                return Array(lines.suffix(maxLines))
            }
        }
        return []
    }

    private nonisolated static func findTranscript(id: String, under root: URL) -> URL? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in e where url.lastPathComponent == "\(id).jsonl" { return url }
        return nil
    }
```

> If `TranscriptSource` does not expose `scanRoots()` publicly, add a public `scanRoots() -> [URL]` accessor to it (it already computes roots internally per CLAUDE.md). Keep the change minimal.

Also update the publish signature so the snapshot signature includes armed IDs (so re-publishing fires when arming changes):

```swift
        let signature = snapshot.sessions.map { "\($0.id):\($0.totalTokens):\($0.running.rawValue)" }
            + ["running:\(snapshot.runningCount)", "total:\(snapshot.totalTokens)",
               "armed:\(snapshot.armedSessionIDs.sorted().joined(separator: ","))",
               "armable:\(snapshot.armableSessionIDs.sorted().joined(separator: ","))"]
```

- [ ] **Step 2: Wire everything in `AppDelegate`**

In `Sources/ClaudeMeter/App/AppDelegate.swift`, add owned instances:

```swift
    private let armedSessions = ArmedSessions()
    private let sleepInhibitor = SleepInhibitor()
    private lazy var autoResume = AutoResumeCoordinator(
        armed: armedSessions,
        settings: settings,
        notify: { [weak self] message in self?.notifications.post(title: "ClaudeMeter", body: message) }
    )
```

> Use whatever the existing `NotificationManager` posting API is; if it differs from `post(title:body:)`, match it. This is the quiet skip/error notification path from the spec.

In `applicationDidFinishLaunching`, after `sessionMonitor.start()`:

```swift
        // Feed armed IDs into published snapshots and run auto-resume after each scan.
        sessionMonitor.armedIDsProvider = { [weak self] in Array(self?.armedSessions.armed ?? []) }
        sessionMonitor.onScan = { [weak self] inputs in
            guard let self else { return }
            // Apply any arm/disarm requests issued from the widget. Arm requests
            // are re-validated against the current armable set.
            let armable = Set(self.sessionMonitor.armableSessionIDs(
                sessions: inputs.sessions, processes: inputs.processes))
            if self.armedSessions.drainWidgetCommands(isArmable: { armable.contains($0) }) {
                Task { await self.sessionMonitor.refresh() }   // re-publish updated armed state
            }
            // Keep the Mac awake while anything is armed.
            self.sleepInhibitor.update(active: !self.armedSessions.armed.isEmpty)
            // Drive auto-resume.
            self.autoResume.handleSnapshot(
                usage: self.store.snapshot,
                sessions: inputs.sessions,
                processes: inputs.processes,
                transcriptTail: { SessionMonitor.tailLines(forSessionID: $0) },
                paths: { LibprocProcessProbe.executablePathForPID($0) },
                parents: { LibprocProcessProbe.parentPIDForPID($0) }
            )
        }
        // React to arming changes immediately (sleep assertion + republish).
        armedSessions.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.sleepInhibitor.update(active: !self.armedSessions.armed.isEmpty)
                Task { await self.sessionMonitor.refresh() }
            }
            .store(in: &cancellables)
```

> The closures `LibprocProcessProbe.executablePathForPID(_:)` / `parentPIDForPID(_:)` need to be **public static** wrappers. In Task 1's `ProcessProbe.swift`, expose them: `public static func executablePathForPID(_ pid: Int32) -> String? { executablePath(pid) }` and `public static func parentPIDForPID(_ pid: Int32) -> Int32 { parentPID(pid) }`. Add these two lines when implementing this task.

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds without errors.

- [ ] **Step 4: Manual smoke test (no arming yet)**

Run: `./build.sh --install` then launch. Open the Sessions window; confirm it still lists sessions and the app runs normally. Auto-resume is off by default, so nothing fires.
Expected: app behaves exactly as before; no crashes in Console.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeMeter/App/SessionMonitor.swift Sources/ClaudeMeter/App/AppDelegate.swift Sources/ClaudeMeterCore/Services/ProcessProbe.swift
git commit -m "feat(app): wire auto-resume coordinator, sleep inhibitor, armed snapshot"
```

---

### Task 13: Sessions window — arm toggle + armed badge

**Files:**
- Modify: `Sources/ClaudeMeter/Views/SessionRow.swift`
- Modify: `Sources/ClaudeMeter/Views/SessionsView.swift`

**Interfaces:**
- Consumes: `ArmedSessions` (9), `SessionMonitor.latestProcesses` (12), `AutoResumeCoordinator.terminalKind(forCwd:...)` (10) for drivability; `TerminalKind` (3).
- Produces: per-row arm toggle bound to `ArmedSessions`, enabled only for iTerm2 sessions; "N armed" header badge.

`SessionsView` currently owns only `monitor`. Inject `armed` and a way to resolve terminal kind. Pass `ArmedSessions` and a precomputed `[sessionID: TerminalKind]` map (built in the view from `monitor.latestProcesses`) to avoid per-row libproc calls.

- [ ] **Step 1: Update `SessionsWindowController` / `SessionsView` construction**

`SessionsView` needs `armed`. In `AppDelegate`, the window is `SessionsWindowController(monitor: sessionMonitor)`. Update that controller to also take `armed: armedSessions` and forward it to `SessionsView`. In `Sources/ClaudeMeter/Views/SessionsView.swift` add:

```swift
    @ObservedObject var armed: ArmedSessions
```

and compute a terminal-kind map from `monitor.latestProcesses` using a `TerminalDetector`:

```swift
    private var terminalKinds: [String: TerminalKind] {
        let detector = TerminalDetector()
        let index = SessionProcessIndex(processes: monitor.latestProcesses)
        var map: [String: TerminalKind] = [:]
        for session in monitor.sessions {
            map[session.id] = index.terminalKind(
                forCwd: session.projectPath, detector: detector,
                paths: { LibprocProcessProbe.executablePathForPID($0) },
                parents: { LibprocProcessProbe.parentPIDForPID($0) })
        }
        return map
    }
```

- [ ] **Step 2: Add the armed badge to the header**

In the header `HStack` of `SessionsView`, after the existing summary text:

```swift
                if armed.count > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill").font(.system(size: 10))
                        Text("\(armed.count) armed").font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.18)))
                    .foregroundStyle(.orange)
                }
```

- [ ] **Step 3: Pass arm state into each row**

Where rows are built (`ForEach(visibleSessions) { SessionRow(session: $0, now: now) }`), change to:

```swift
                ForEach(visibleSessions) { session in
                    SessionRow(
                        session: session, now: now,
                        terminalKind: terminalKinds[session.id] ?? .unknown,
                        isArmed: armed.isArmed(session.id),
                        onArmChange: { armed.setArmed(session.id, $0) })
                }
```

- [ ] **Step 4: Add the toggle to `SessionRow`**

In `Sources/ClaudeMeter/Views/SessionRow.swift`, extend the struct:

```swift
struct SessionRow: View {
    let session: SessionUsage
    let now: Date
    var terminalKind: TerminalKind = .unknown
    var isArmed: Bool = false
    var onArmChange: (Bool) -> Void = { _ in }
```

Add a trailing arm control in the row's `HStack` (after the tokens). Only iTerm2 + running sessions can be armed:

```swift
            let canArm = terminalKind.isDrivable && session.running == .running
            Toggle("", isOn: Binding(get: { isArmed }, set: { onArmChange($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .disabled(!canArm)
                .help(canArm
                      ? "Auto-resume this session when quota refreshes"
                      : (session.running != .running
                         ? "Only live sessions can be armed"
                         : "Supports iTerm2 only for now (\(terminalKind.displayName))"))
```

- [ ] **Step 5: Build + manual test**

Run: `swift build` then `./build.sh --install` and launch. Open the Sessions window.
Expected: each live iTerm2 session row shows an enabled switch; non-iTerm2 / idle rows show a disabled switch with a tooltip. Toggling one shows the "1 armed" badge and (via the `objectWillChange` wiring) the menu stays responsive. Quitting and relaunching preserves the armed switch (persistence).

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeMeter/Views/SessionRow.swift Sources/ClaudeMeter/Views/SessionsView.swift Sources/ClaudeMeter/App/AppDelegate.swift
git commit -m "feat(app): per-session arm toggle and armed badge in Sessions window"
```

---

## Phase D — Widget (display + interactive arm & disarm)

### Task 14: Widget armed/armable indicators + arm & disarm App Intents

**Files:**
- Create: `Widget/SessionArmIntents.swift`
- Modify: `Widget/ClaudeMeterWidget.swift`
- Modify (if needed): `project.yml` (ensure the widget target compiles the new file — it already globs `Widget/`, so no change unless source list is explicit; verify).

**Interfaces:**
- Produces: `struct ArmSessionIntent: AppIntent` and `struct DisarmSessionIntent: AppIntent`, each with `@Parameter var sessionID: String`; `perform()` appends a `WidgetCommand(.arm/.disarm, sessionID:)` to the widget's command inbox and reloads timelines.
- Consumes: `SessionSnapshot.armedSessionIDs` + `armableSessionIDs` (5), `ArmedSessionsStore` + `WidgetCommand` (4).

The widget already reads `snapshot.json` from its own container; it writes `widget-commands.json` into the **same** container — which it is allowed to do — and the app drains + re-validates it (Task 9/12).

- [ ] **Step 1: Create the App Intents**

Create `Widget/SessionArmIntents.swift`:

```swift
import AppIntents
import WidgetKit
import Foundation
import ClaudeMeterCore

/// Widget command inbox: the widget's own container Documents, the same path
/// `Provider.loadEntry()` reads `snapshot.json` from. Matches the app's
/// `ArmedSessions.commandInboxURL()`.
private func widgetCommandURL() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("widget-commands.json")
}

private func queue(_ command: WidgetCommand) throws {
    try ArmedSessionsStore().appendCommand(command, to: widgetCommandURL())
    WidgetCenter.shared.reloadAllTimelines()
}

/// Tapped from the widget to ARM a session. The sandboxed widget can't write the
/// app's armed store, so it appends a request the app drains, re-validates
/// (iTerm2 + running), and applies on its next scan.
struct ArmSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Arm Session"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Session ID") var sessionID: String
    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    func perform() async throws -> some IntentResult {
        try queue(WidgetCommand(action: .arm, sessionID: sessionID))
        return .result()
    }
}

/// Tapped from the widget to DISARM a session.
struct DisarmSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Disarm Session"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Session ID") var sessionID: String
    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    func perform() async throws -> some IntentResult {
        try queue(WidgetCommand(action: .disarm, sessionID: sessionID))
        return .result()
    }
}
```

- [ ] **Step 2: Render armed/armable state + arm & disarm buttons in the widget**

In `Widget/ClaudeMeterWidget.swift`, give the entry view access to armed + armable IDs and add an indicator + toggle button to `sessionBar`. Add computed sets:

```swift
    private var armedIDs: Set<String> { Set(entry.snapshot?.armedSessionIDs ?? []) }
    private var armableIDs: Set<String> { Set(entry.snapshot?.armableSessionIDs ?? []) }
```

Update `sessionBar(_:)` so an armed session shows a bolt + a disarm button, and an armable-but-not-armed session shows an arm button (medium/large only — `systemSmall` has no room):

```swift
    @ViewBuilder private func sessionBar(_ s: SessionUsage) -> some View {
        let isArmed = armedIDs.contains(s.id)
        let canArm = armableIDs.contains(s.id)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if isArmed {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
                Text(s.projectName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(Formatting.tokenCount(s.totalTokens))
                    .font(.system(size: 12, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                if family != .systemSmall {
                    if isArmed {
                        Button(intent: DisarmSessionIntent(sessionID: s.id)) {
                            Image(systemName: "bolt.slash.fill").font(.system(size: 10))
                        }
                        .buttonStyle(.plain).foregroundStyle(.orange)
                        .help("Disarm auto-resume")
                    } else if canArm {
                        Button(intent: ArmSessionIntent(sessionID: s.id)) {
                            Image(systemName: "bolt").font(.system(size: 10))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Arm overnight auto-resume")
                    }
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule().fill(activeGradient)
                        .frame(width: max(8, geo.size.width * CGFloat(s.totalTokens) / CGFloat(maxTokens)))
                }
            }
            .frame(height: 7)
        }
    }
```

Add an "N armed" chip to the widget `header` next to `livePill`:

```swift
            if let armed = entry.snapshot?.armedSessionIDs, !armed.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill").font(.system(size: 9))
                    Text("\(armed.count)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                }
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.18)))
                .foregroundStyle(.orange)
            }
```

> The widget snapshot is built `runningOnly: true`, so only running sessions appear. An armed session that is idle/cut-off may not be in the widget's session list. To ensure armed sessions are always visible for disarming, the snapshot must include armed sessions even when not running — see Task 15. (Arming is only offered for running iTerm2 sessions, which are always in the running set, so no extra inclusion is needed for arm targets.)

- [ ] **Step 3: Build the Xcode (widget) project**

Run: `./build-xcode.sh` (or `xcodegen generate && xcodebuild -project ClaudeMeter.xcodeproj -scheme ClaudeMeter -configuration Release build`).
Expected: app + widget compile. If `project.yml` lists explicit sources for the widget, confirm `Widget/SessionArmIntents.swift` is picked up (the `- path: Widget` glob covers it).

- [ ] **Step 4: Commit**

```bash
git add Widget/SessionArmIntents.swift Widget/ClaudeMeterWidget.swift
git commit -m "feat(widget): arm & disarm sessions from the widget"
```

---

### Task 15: Ensure armed sessions always appear in the widget snapshot

**Files:**
- Modify: `Sources/ClaudeMeter/App/SessionMonitor.swift`

**Interfaces:**
- Consumes: `SessionSnapshot` (5), armed IDs provider (12).
- Produces: a snapshot whose `sessions` always include every armed session (even idle/cut-off), so the widget can render + disarm them.

The current `make(..., runningOnly: true)` drops idle sessions. An armed session that hit its limit is idle, so it would vanish from the widget exactly when the user most wants to see/disarm it. Build the widget snapshot from running sessions **plus** armed sessions.

- [ ] **Step 1: Replace the snapshot construction in `refresh()`**

In `Sources/ClaudeMeter/App/SessionMonitor.swift`, change the snapshot build added in Task 12 to union running + armed:

```swift
        let armedSet = Set(armedIDs)
        let armable = armableSessionIDs(sessions: result.sessions, processes: processes)
        let widgetSessions = result.sessions.filter { $0.running == .running || armedSet.contains($0.id) }
        let snap = SessionSnapshot.make(
            from: widgetSessions, now: result.snapshot.generatedAt,
            limit: 12, runningOnly: false, armedSessionIDs: armedIDs, armableSessionIDs: armable)
        // Preserve the true running count across ALL sessions, not just the filtered set.
        let trueRunning = result.sessions.filter { $0.running == .running }.count
        snapshot = SessionSnapshot(
            generatedAt: snap.generatedAt, sessions: snap.sessions,
            totalTokens: result.sessions.reduce(0) { $0 + $1.totalTokens },
            runningCount: trueRunning, armedSessionIDs: armedIDs, armableSessionIDs: armable)
        lastUpdated = snapshot!.generatedAt
        publish(snapshot!)
```

> Rationale: `runningOnly: false` keeps armed-but-idle sessions; we then fix `totalTokens`/`runningCount` to reflect all sessions (matching the prior semantics the widget header shows).

- [ ] **Step 2: Build + verify**

Run: `swift build`
Expected: builds. Then `./build-xcode.sh` to rebuild the widget host.

- [ ] **Step 3: Manual end-to-end widget check (arm + disarm both directions)**

1. Add/refresh the widget (per CLAUDE.md, you may need `killall chronod` after reinstall).
2. With a running iTerm2 session present and **not** armed, expected: the widget shows an outline-bolt **arm** button on that row. Tap it → within ~10s the session shows a filled bolt and the "N armed" chip increments; the Sessions window switch flips on too.
3. Tap the **disarm** (bolt.slash) button → within ~10s the arm clears in both the widget and the Sessions window.
4. Arm from the Sessions window switch → the widget reflects it on the next refresh. (Both surfaces stay in sync because the app is the single source of truth.)
5. Confirm a non-iTerm2 / idle session shows **no** arm button in the widget (not in `armableSessionIDs`), and that a stale arm request for such a session is rejected by the app's re-validation.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeMeter/App/SessionMonitor.swift
git commit -m "feat(app): keep armed sessions visible + publish armable set for widget"
```

---

## Phase E — Integration verification

### Task 16: Coordinator behavior test with a mock driver (optional but recommended)

**Files:**
- Create: `Tests/ClaudeMeterCoreTests/` — N/A (coordinator is App-target). If a test target for the app exists, add there; otherwise verify manually per the steps below.

> The app target has no unit-test bundle in `Package.swift` (only `ClaudeMeterCoreTests`). The coordinator's *decision* inputs (cutoff classification, terminal detection, tally) are already unit-tested in Core. The coordinator's wiring is verified by the manual end-to-end test below. Do **not** add an app test target in v1 unless you also add it to `Package.swift`.

- [ ] **Step 1: Manual end-to-end resume test (real iTerm2)**

Preconditions: at least one iTerm2 tab running `claude` that has hit the 5-hour limit (tail shows the synthetic limit marker), and `autoResumeEnabled` on.

1. Arm that session in the Sessions window.
2. Confirm the Mac is kept awake (`pmset -g assertions | grep PreventUserIdleSystemSleep` shows ClaudeMeter while ≥1 armed).
3. When quota refreshes (or simulate: temporarily lower `UsageStats.didRefill` sensitivity is NOT recommended — instead wait for a real reset, or arm right before a known reset), confirm ClaudeMeter triggers the macOS Automation permission prompt the first time, and after granting, `continue` is typed into that exact tab.
4. Confirm a cleanly-finished armed session is NOT nudged.
5. Confirm a non-iTerm2 armed attempt is blocked at the UI (toggle disabled).

Expected: only the cut-off iTerm2 session receives `continue`, in its own tab, without focus stealing.

- [ ] **Step 2: Permission-denied path**

Deny Automation permission (System Settings → Privacy & Security → Automation) and trigger a fire.
Expected: a quiet notification explains the resume was skipped and how to enable Automation; the app does not crash or repeatedly prompt.

- [ ] **Step 3: Final full-suite run**

Run: `swift test`
Expected: all Core suites green.

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "test: verify auto-resume end-to-end and permission paths"
```

---

## Self-Review

**Spec coverage**

| Spec item | Task |
|-----------|------|
| Per-session arming UI, persisted | 9, 13, 11 |
| Quota-refresh trigger from `UsageStore` reset/utilization | 10, 12 (`UsageStats.didRefill`) |
| Pure TDD'd cut-off + idle eligibility gate | 2 (`CutoffDetector`) |
| iTerm2 delivery by tty + verified live PID | 7, 8, 10 (tty match + unique-cwd verify) |
| Terminal detection / graceful degradation | 1, 3, 8, 13 |
| Automatic sleep inhibition while armed | 6, 12 |
| `ArmedSessionsStore` model + codable persistence | 4, 9 |
| `AutoResumeCoordinator` orchestration | 10, 12 |
| `TerminalResumeDriver` protocol + `ITermDriver` | 7 |
| libproc probe gains tty + parent PID | 1 |
| Repeat across resets until disarm | 10 (`firedThisCrossing` cleared on use) |
| Skip cleanly-finished / already-running / no-double-nudge | 2, 10 |
| Stagger, no cap | 10 (`staggerSeconds`, no cap) |
| Permissions (Automation) error surfaced | 7, 10 (notify), 16 |
| Settings: enable toggle + editable continue text | 11 |
| Widget shows armed dynamically (new requirement) | 5, 14, 15 |
| Widget interactive **arm and disarm** (new requirement) | 4, 5, 9, 12, 14, 15 |
| App re-validates widget arm requests (iTerm2 + running) | 9, 12 (`isArmable`) |
| Arm/disarm from Sessions window, in sync with widget | 9, 13 |

**Placeholder scan:** No TBD/TODO; each code step contains full code. The two non-code verification tasks (16) are manual system tests by necessity (live iTerm2 + real quota reset + TCC prompt), with explicit expected outcomes.

**Type consistency:** `LiveProcess(pid:cwd:tty:ppid:)`, `CutoffDetector.classify(tailLines:isRunning:)`, `SessionEligibility.shouldFire`, `TerminalKind.isDrivable/displayName`, `ArmedSessionsStore.{read,write,appendCommand,drainCommands}`, `WidgetCommand(action:sessionID:)`, `SessionSnapshot.armedSessionIDs` / `make(...,armedSessionIDs:)`, `ResumeTarget(sessionID:tty:continueText:)`, `TerminalResumeDriver.resume(_:)`, `Settings.autoResumeEnabled/normalizedContinueText`, `ArmedSessions.{isArmed,setArmed,disarm,disarmAll,drainWidgetCommands,armed,count}`, `AutoResumeCoordinator.handleSnapshot(...)`, `LibprocProcessProbe.{liveClaudeProcesses,tally(processes:),executablePathForPID,parentPIDForPID}` — names are used consistently across tasks.

**Known assumptions to validate during execution (flagged, not placeholders):**
- `TranscriptSource` exposes (or gains a minimal public) `scanRoots() -> [URL]` — Task 12.
- `NotificationManager`'s posting API signature — Task 12 (`notify` closure adapts to it).
- The synthetic usage-limit text wording may evolve; `CutoffDetector` matches on `isApiErrorMessage` + `model == "<synthetic>"` + text contains "limit", which is resilient to wording changes — Task 2.
