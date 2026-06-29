# ClaudeMeter — Overnight Auto-Resume

**Date:** 2026-06-29
**Status:** Approved design
**Branch:** `feat/auto-resume` (proposed)

## Goal

Let the user **arm specific live Claude Code sessions** before walking away so that,
whenever the subscription quota refreshes, ClaudeMeter automatically nudges each
armed session that was **cut off mid-task by the usage limit** to continue — by
typing `continue` into that session's exact iTerm2 tab. The work resumes in the
**real, live interactive session** (full context and history, in the tab the user
expects), repeating across every quota reset until the user disarms it.

Primary question answered: *"My 5-hour quota ran out mid-task and I'm asleep —
can the work pick up by itself the moment quota frees up, without me babysitting
the terminal?"*

## Why driving the live tab (not `claude --resume`)

The earlier feasibility note held that text cannot be injected into a live `claude`
session — but that is only true of the **CLI**, which has no such API. Driving the
**terminal emulator** is a different layer: macOS can deliver input into an
already-running interactive program through the emulator's automation API.

When the 5-hour limit is hit interactively, the `claude` REPL does **not** die — it
prints the limit message and sits at its prompt. So the natural mechanism is simply:
*when quota refreshes, type `continue` + Enter into that still-live session.* This is
preferred over headless `claude --resume <id> -p`:

- Continues the **real, live session** in place — no forked process, no separate
  `--resume`, full context and history preserved.
- Permissions are whatever that live session **already** has — no need to plumb a
  `bypassPermissions` flag into an unattended headless run.
- The user comes back to progress in the tab they left, not a detached process.

## Decisions (resolved during brainstorming)

| Question | Decision |
|----------|----------|
| Mechanism | Drive the **live iTerm2 tab** of each session (type `continue`). |
| Selection | **Opt-in per session** — armed by the user in the Sessions window. |
| Repeat behavior | **Repeat at every quota reset** until manually disarmed. |
| Stop condition | **Manual disarm only** (no clock cutoff, no max count). |
| Safety gate | Only nudge a session that is **idle AND cut off mid-task** (pending work). A cleanly-finished session stays armed but never fires. |
| Terminal support (v1) | **iTerm2 only**; other terminals degrade gracefully (disabled toggle). |
| Continue text | Global, editable; default **`continue`**. |
| Staying awake | Auto IOKit power assertion while ≥1 session is armed. |
| Firing multiple | Fire all armed-eligible sessions with a small **stagger**, **no cap**. |

## Scope

**In scope**

- Per-session arming UI in the existing Sessions window, persisted across restarts.
- Quota-refresh trigger driven by existing `UsageStore` reset/utilization data.
- A pure, TDD'd **cut-off + idle** eligibility gate over the transcript tail.
- An iTerm2 delivery driver that targets the correct session by **tty + verified
  live PID**.
- Terminal detection (which emulator owns each session) for graceful degradation.
- Automatic sleep inhibition while sessions are armed.

**Out of scope (v1)**

- Terminals other than iTerm2 (Terminal.app, Ghostty, WezTerm, Warp, VS Code
  integrated) — detected and shown as "not supported yet", added later as new
  drivers behind the same protocol.
- Headless `claude --resume` execution.
- Desktop agent / Cowork sessions (run in a sandbox/VM with no host-visible tty —
  not drivable).
- Quota-stampede protection beyond a small firing stagger (multiple armed tabs may
  drain the refreshed quota quickly; this is expected behavior).
- Clock-based or count-based auto-disarm.

## User experience

1. User is working across several iTerm2 tabs; one or more hit the 5-hour limit
   mid-task. Before going to bed, the user opens the Sessions window and **arms**
   the sessions they want resumed.
2. ClaudeMeter keeps the Mac awake while anything is armed.
3. At the next quota refresh, for each armed session ClaudeMeter checks the gate; if
   the session is idle and was cut off with work pending, it types `continue` into
   that session's iTerm2 tab. Work resumes.
4. The session may run, exhaust quota again, and stop. At the **next** reset it is
   nudged again. This repeats until the user disarms it.
5. If an armed session has actually finished (clean completion), it is **skipped** —
   it stays armed but never fires, so a forgotten armed session does no spurious
   work.

## Architecture

Follows the existing strict split: pure, testable logic in `ClaudeMeterCore`; AppKit
/ system integration in `ClaudeMeter`.

### Core (`ClaudeMeterCore`, pure, TDD)

- **`CutoffDetector`** — given the parsed transcript tail and running state, returns
  whether a session is **eligible**: idle (alive, at a prompt, not already running)
  **and** stopped at the usage limit with work pending (interrupted/unfinished
  assistant turn, or a user prompt with no completed assistant response). Clean
  completion or already-running → not eligible. Reuses `TranscriptParser`.
- **`ArmedSessionsStore` model** — the set of armed session UUIDs (pure value type
  + codable representation for persistence).

### App (`ClaudeMeter`)

- **`AutoResumeCoordinator`** (`@MainActor`) — orchestrator. Observes `UsageStore`
  for a **quota-refresh crossing** (reset time passes / utilization drops) and the
  latest `SessionMonitor` snapshot (already rescanned every 10s). On a refresh, for
  each armed session it runs `CutoffDetector`; eligible sessions are dispatched to
  the driver with a small stagger. Marks fired sessions as running so they are not
  re-nudged until idle-and-cut-off at a later reset.
- **`TerminalResumeDriver`** (protocol) — `func resume(session:) throws`. Mockable
  for tests.
  - **`ITermDriver`** (v1 impl) — via ScriptingBridge/AppleScript. Matches the
    session's controlling **tty** to an iTerm2 session, **verifies the live PID/cwd
    still belong to the same `claude` process**, then `write text` the continue
    string to that exact session. Never focuses/steals a tab. If the
    tab/session/iTerm is gone → throws → coordinator skips + posts a quiet
    notification.
- **`TerminalDetector`** — walks the `claude` PID's parent-process chain (libproc
  parent PIDs) to the owning terminal bundle (iTerm2 / Terminal / Ghostty / …). Used
  to enable arming only for drivable (iTerm2) sessions and to label others.
- **`SleepInhibitor`** — holds an IOKit `PreventUserIdleSystemSleep` power assertion
  while ≥1 session is armed; releases when none are armed.
- **Settings additions** — feature enable toggle, editable continue text (default
  `continue`), and Automation-permission status/help.
- **`SessionsView` additions** — per-row **arm toggle** (enabled only for iTerm2
  sessions; disabled with tooltip otherwise), and an "N armed" header badge.

### Supporting change

- **libproc probe** (`ProcessProbe` / `RunningResolver`) gains **controlling tty**
  and **parent PID** for each live `claude` process, so sessions can be matched to
  iTerm2 sessions and to their owning terminal.

## Data flow

```
UsageStore (reset/utilization)  ─┐
                                 ├─> AutoResumeCoordinator
SessionMonitor snapshot ─────────┘        │
ArmedSessionsStore (persisted) ───────────┤
                                          │  for each armed session:
                            CutoffDetector │  (transcript tail + running state)
                                          │  eligible? ── no ─> skip
                                          │      │ yes
                            TerminalDetector│  iTerm2? ── no ─> skip (shouldn't arm)
                                          │      │ yes
                               ITermDriver │  match tty + verify PID -> write "continue"
                                          ▼
                                  mark running; notify on skip/error
```

## Persistence & identity

- Sessions are identified by the **session UUID** (transcript filename), stable for
  the life of a session.
- The armed set is persisted (Settings/UserDefaults) so arming survives an app
  restart overnight.
- A session UUID is mapped to a live PID/tty via the (extended) libproc probe and
  `RunningResolver`'s existing cwd correlation.

## Permissions (macOS TCC)

- Controlling iTerm2 requires the **Automation** entitlement at runtime. The first
  arm-and-fire triggers the standard "ClaudeMeter wants to control iTerm2" prompt.
- If denied, the coordinator surfaces a clear, actionable error (how to enable it in
  System Settings → Privacy & Security → Automation) and does not fire.
- This is the only install-adjacent requirement; nothing changes in the build/install
  flow, and `ITermDriver` is ordinary compiled code (not a separately installed
  component).

## Error handling & edge cases

- **Tab/session closed or iTerm not running** → driver throws → skip + quiet
  notification.
- **tty reused** by a different process → PID/cwd verification fails → do not write
  (prevents typing into the wrong program).
- **Already running** at reset → not eligible → skip (no double-nudge).
- **Cleanly finished** session → not eligible → skip (stays armed, never fires).
- **Quota stampede** → all eligible armed sessions fire (small stagger, no cap);
  refreshed quota may drain quickly. Expected, documented, not prevented.
- **Closed laptop lid on battery** can still sleep despite the power assertion;
  surface a one-time hint (keep lid open or stay on power).
- **Non-iTerm2 terminal** → arm toggle disabled with "supports iTerm2 only for now".

## Testing

- **`CutoffDetector`** — fully TDD'd against transcript fixtures: cut-off mid-task,
  cleanly finished, awaiting user input, already running. This is the safety-critical
  unit.
- **`AutoResumeCoordinator`** — unit-tested with a **mock `TerminalResumeDriver`**, a
  mock clock / reset source, and a fake armed set: verifies firing on refresh,
  gating, no-double-nudge, repeat across resets, and skip/notify paths.
- **`TerminalDetector`** — unit-tested over synthetic parent-chain fixtures.
- **`ITermDriver`** — thin; the AppleScript/ScriptingBridge path verified manually
  against a real iTerm2 (tty match, PID verification, `write text`). Kept minimal so
  most logic lives in tested units.

## Open follow-ups (not v1)

- Additional `TerminalResumeDriver` implementations (Terminal.app, Ghostty, …).
- Optional per-session custom continue text.
- Optional quota-stampede pacing (e.g. resume one tab at a time, wait for it to go
  idle before the next).
- Optional clock/count-based auto-disarm.
