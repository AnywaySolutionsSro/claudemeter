# ClaudeMeter — Live Sessions, Settings Window & Widget

**Date:** 2026-06-28
**Status:** Approved design
**Branch:** `feat/live-sessions`

## Goal

Give the user an at-a-glance view of **token consumption per running Claude Code
session** on the local machine. Primary question answered: *"Which session is
eating tokens right now, and how much has each session used?"*

The headline metric per session is **total tokens this session**; live "Running"
status tells the user which sessions are still active.

## Scope

Tracked (both share one JSONL parser):

- **CLI sessions** — `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`
- **Desktop agent / Cowork / code sessions** — the desktop app writes the same
  CLI-style transcripts under
  `~/Library/Application Support/Claude/local-agent-mode-sessions/**/.claude/projects/**/*.jsonl`

Explicitly **out of scope**: plain Claude.app **chat** conversations. Those are
server-side; the local IndexedDB/cache holds no per-message token usage, so they
cannot be tracked from local files. This is an Anthropic-side limitation.

## Empirical findings (validated 2026-06-28)

- Each assistant record carries `message.usage` with `input_tokens`,
  `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`,
  plus `model`, `timestamp`, and `cwd`.
- Transcript files are **not** held open by the writing process (append-and-close
  per write), so `lsof`-on-file cannot detect liveness.
- Each live `claude` process **does** expose a readable working directory
  (`proc_pidinfo` / `lsof -d cwd`) that maps to a project's transcripts. This
  correctly flags **idle-but-open** sessions that an mtime rule would miss.
- Desktop agent sessions run inside the app's sandbox/VM (`claude-code-vm`,
  `vm_bundles`) and do **not** expose a host-visible cwd; their liveness is
  inferred from `lastActivityAt` recency + `Claude.app` running.
- `claude-code-sessions/*.json` provide a human-readable `title` per session.

## Token-total definition (locked)

Cache-read tokens repeat every turn and would inflate a naive sum into the
millions. Therefore:

- **Headline total = `input_tokens + output_tokens + cache_creation_input_tokens`**
  summed across all assistant records.
- **Cache-read tokens** are aggregated and shown **separately** ("+N cached").
- Use the **top-level** usage fields, not the `iterations[]` breakdown.

## Architecture

Four layers, ordered so each is independently testable and the risky packaging
change lands last.

```
ClaudeMeterCore (pure, SwiftPM, TDD)                 ← Phase 1
  ├─ Models: SessionUsage, TokenBreakdown, SessionOrigin, RunningState
  ├─ TranscriptParser    JSONL lines → partial SessionUsage (lenient)
  ├─ SessionAggregator   token math, totals, burn rate, model set
  ├─ RunningResolver     (cwd→live-count, sessions) → who is Running
  └─ SessionSnapshot     Codable payload shared with the widget

ClaudeMeter app                                       ← Phases 2–4
  ├─ TranscriptSource    enumerate scan roots (CLI + desktop), read cwd/title
  ├─ ProcessProbe        live claude PIDs + cwds via libproc   [protocol]
  ├─ SessionMonitor      actor: timer scan → parse changed → publish + snapshot
  ├─ SessionsWindow      SwiftUI live list
  └─ SettingsWindow      existing config moved out of popover

ClaudeMeterWidget (.appex)                            ← Phase 5
  └─ reads App-Group snapshot.json on a WidgetKit timeline
```

### A. Sessions engine (`ClaudeMeterCore`) — pure & TDD

- **`SessionUsage`** value type: `id`, `projectPath`, `projectName`, `title?`,
  `origin` (`.cli` / `.desktop`), `models: Set<String>`, `tokens:
  TokenBreakdown`, `totalTokens`, `cacheReadTokens`, `firstActivity`,
  `lastActivity`, `messageCount`, `running: RunningState`, `lastPromptPreview?`.
- **`TokenBreakdown`** value type: `input`, `output`, `cacheCreation`,
  `cacheRead`. `totalTokens = input + output + cacheCreation`.
- **`TranscriptParser`**: lenient line-by-line decode. Skip non-JSON and
  non-`assistant` records; never throw on a bad line (count and continue). Pull
  top-level `usage`, `model`, `timestamp`, `cwd`.
- **`SessionAggregator`**: fold parsed records into one `SessionUsage`; compute
  burn rate (tokens within a trailing window, default 5 min) as a secondary
  metric; collect the model set.
- **`RunningResolver`**: given `cwd → live-process-count` and all sessions, mark
  the *N* most-recently-active CLI transcripts in each cwd as `.running`; desktop
  sessions marked `.running` when `lastActivity` is within a recency threshold and
  the desktop app is alive. Pure function → exhaustively unit-tested.

### B. Live Sessions window

A real window opened from the menu ("Sessions…"). Rows sorted by **total tokens**
desc: project name · origin badge (CLI/Desktop) · model badge · **total tokens** ·
burn rate (secondary) · last-activity · 🟢 Running / ⚪️ idle. Header shows
aggregate total + running count. Refreshes every few seconds while visible.

### C. Settings → dedicated window

Move current popover config (skin, notification thresholds, login-item, hotkey,
accounts) into a tabbed Settings window opened from the Settings button:
General / Appearance / Notifications / Accounts. The popover slims to live usage +
links to Sessions and Settings.

### D. macOS widget

Introduce an **XcodeGen-generated** Xcode project (manifest = config-as-code) so
`ClaudeMeterCore` stays a SwiftPM package that the app + widget both depend on.
The app writes a small `snapshot.json` (top sessions + totals + timestamp) to an
**App Group**; the widget reads it on a WidgetKit timeline.

- Sizes: `systemSmall` (top session + total), `systemMedium` (top 3),
  `accessoryRectangular` (Notification Center).
- Shows "updated Xm ago" — WidgetKit refresh is system-throttled, so cadence is
  near-live, not real-time. The menu-bar app remains the real-time surface.
- The widget only reads the snapshot; it never runs `libproc`/process probes.

## Data flow

`SessionMonitor` actor, every ~3–5 s (configurable):

1. `TranscriptSource` enumerates scan roots; skip transcripts whose mtime is
   unchanged since last tick (offset/mtime cache) to avoid re-parsing.
2. Parse changed transcripts → partial `SessionUsage`.
3. `ProcessProbe` returns live `claude` cwds (CLI liveness).
4. `RunningResolver` composes the final `[SessionUsage]`.
5. Publish to `@MainActor` UI **and** write the App-Group `snapshot.json`.

## Error handling

- Missing scan root → empty state, no crash.
- Malformed JSONL line → skipped and counted; parser never throws.
- No process-probe access (hardened runtime / permission) → degrade to mtime
  recency for liveness and show a subtle "approximate" indicator.
- Stale widget snapshot → render its age.
- Per-PID cwd read failure → skip that PID.

## Testing (TDD, latest standards)

- New core logic written **test-first with swift-testing**; existing XCTest
  suites remain.
- Fixtures: representative JSONL lines (CLI + desktop, good + malformed) →
  expected `SessionUsage`.
- Truth tables for `RunningResolver` (single/multiple sessions per cwd, idle,
  desktop recency).
- `ProcessProbe` behind a protocol, faked in tests.
- Swift 6 language mode / strict concurrency throughout. Target ≥80% on core.

## Build phases

1. **A** — core models, `TranscriptParser`, `SessionAggregator`,
   `RunningResolver`, `SessionSnapshot` (pure, TDD). No UI.
2. **A′** — `TranscriptSource` (CLI + desktop roots), `ProcessProbe` (libproc),
   `SessionMonitor` orchestrator.
3. **B** — Live Sessions window.
4. **C** — Settings window refactor.
5. **D** — XcodeGen migration + widget + App-Group snapshot.

## Open items / risks

- XcodeGen migration (Phase 5) changes the build/sign/notarize flow in
  `build.sh`; treat as its own milestone with a working rollback to the current
  SwiftPM bundle.
- Desktop liveness is heuristic (recency + app-alive); acceptable since totals
  persist regardless of the running flag.
