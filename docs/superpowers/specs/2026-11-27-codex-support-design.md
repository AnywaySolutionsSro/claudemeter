# Codex support — design

Date: 2026-11-27 · Status: draft for approval

## Intent

Jakub uses both Claude Code and OpenAI Codex. ClaudeMeter should watch Codex the way it
watches Claude — limit windows, live sessions with token counts, and **auto-resume of
terminal sessions after a limit refills** — and show both side by side, colour-coded, in the
dropdown and the widgets. One place to see "how much of each do I have left, and what's
running".

## Goals

- Codex limit windows (% left + reset time) in the dropdown and widgets, next to Claude's.
- Codex sessions in the Sessions window and session widgets, with token totals and running state.
- Auto-resume for Codex sessions running in an iTerm2 terminal (same arm/retry/notify model as Claude).
- Claude vs Codex is distinguishable by colour everywhere they appear together.

## Non-goals

- Resuming Codex Desktop (ChatGPT.app) sessions — monitored and listed, never resumed
  (same as plain Claude desktop chat today).
- Codex paid credits / spend tracking.
- A ChatGPT login or any call to OpenAI.

## Anti-goals (failure even if it "works")

- Reading or using Codex's credentials (`~/.codex/auth.json`) — same rule as never touching
  Claude Code's Keychain item.
- Typing `continue` into the wrong tab, or into the desktop app's helper process.
- Any change for a user who doesn't have Codex: no empty Codex section, no new pill.
- Breaking existing on-disk state (`snapshot.json`, `history.json`, armed set) on upgrade.

## Constraints (verified on this machine, 2026-11-27)

- Transcripts: `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<sessionId>.jsonl`. First
  line `session_meta` (`payload.id`, `cwd`, `originator` = `codex-tui` | `Codex Desktop`,
  `cli_version`). Entries are `{timestamp, type, payload}`; `event_msg` payload types include
  `token_count`, `task_started`, `task_complete`.
- `token_count.info.total_token_usage` is **cumulative** for the session (`input_tokens` *includes*
  `cached_input_tokens`; `reasoning_output_tokens` is a subset of `output_tokens`). The last one
  wins — no per-message dedup like Claude needs.
- `token_count.rate_limits` carries the account's limits on every turn:
  `primary`/`secondary` = `{used_percent, window_minutes, resets_at (epoch s)}` or `null`,
  plus `plan_type`, `rate_limit_reached_type`. Jakub's plan (`prolite`) currently has only a
  weekly window (`primary`, 10080 min, `secondary: null`) — **never assume a 5-h window**.
- Thread titles: `~/.codex/session_index.jsonl` (`id`, `thread_name`, `updated_at`).
- Processes: terminal Codex = `~/.codex/packages/standalone/<v>/bin/codex` (symlinked from
  `~/.local/bin/codex`), with a controlling tty. Desktop = `…/ChatGPT.app/…/CodexCLI.app/…/codex`
  and other `ChatGPT.app` helpers, no tty — must never match as resumable.
- **Unverified:** how a usage-limit cutoff is written to the transcript. None of the 11 local
  transcripts has one. The binary contains "You've hit your usage limit… Try again at …"
  and `rate_limit_reached_type` / `usage_limit_reached`. The detector is built from these
  strings and flagged unverified until a real cutoff is captured (see Risks).
- Existing invariants from CLAUDE.md still hold: `LimitWindow.id` is the only comparison key;
  stored models only gain optionals; widget reload budget; widget inbox path from
  `SessionMonitor.widgetBundleID`; a new widget kind needs the chrono cache purge.

## Approaches considered

**Codex limit source**
- **A. Local transcripts (chosen).** Free, offline, no credential. Figure is only as fresh as the
  last Codex turn → shown with "as of …". Refill = the exhausted window's `resets_at` passing.
- B. ChatGPT `/wham/usage` with Codex's `auth.json` token — live, but borrows another app's
  credential (rejected, same reasoning as the Claude Keychain rule).
- C. ClaudeMeter's own ChatGPT OAuth — live and clean, but a large undocumented flow for little gain.

**Code structure**
- **Provider-tagged sessions through the existing pipeline (chosen).** One scanner, Sessions
  window, armed set, planner, iTerm driver; Codex-specific parser, cutoff detector, process
  matcher and limit reader plug in.
- A parallel Codex subsystem — rejected, duplicates ~1,500 lines of tested logic.

## Design (decided)

### Core (`ClaudeMeterCore`, TDD, ≥80% coverage)

- `AgentTool` enum (not `Provider`, which the widget already uses): `.claude`, `.codex`. `SessionUsage` gains `tool: AgentTool?`
  (optional; `nil` decodes as `.claude`). Session IDs stay unique across providers.
- `CodexTranscriptParser`: lenient line-by-line; yields session meta (id, cwd, originator),
  the latest cumulative token usage, latest model, last activity, and the latest
  `rate_limits` reading with its timestamp. Incremental (byte offset) like `SessionScanner`.
  Token mapping into `TokenBreakdown`: input = `input_tokens − cached_input_tokens`,
  cacheRead = `cached_input_tokens`, output = `output_tokens`, cacheCreation = 0.
- `CodexTranscriptSource`: discovers `~/.codex/sessions/**/rollout-*.jsonl`; titles from
  `session_index.jsonl`.
- **Imported Claude threads are not Codex work.** Codex Desktop imports Claude Code sessions
  into `~/.codex/sessions` (listed in `~/.codex/external_agent_session_imports.json`,
  `history_mode: "legacy"`, zero usage, no `rate_limits`). They are skipped — already counted
  as Claude — and don't make the Codex section appear. *(Builder's call:)* an imported thread that
  later accrues Codex tokens is listed as Codex with only those tokens; a session is
  "Codex present" only once it has a non-zero `token_count` or a `rate_limits` reading.
- `CodexLimits` → `[LimitWindow]` built from the **newest** `rate_limits` per `limit_id`
  across all Codex transcripts (+ its `asOf` time). Codex windows live in their own
  collection — `LimitWindow.id` / `UsageGauge.id` are labels, so Claude "Weekly" and Codex
  "Weekly" would collide if mixed.
- *(Builder's call:)* once a window's `resets_at` has passed with no newer reading, it is shown
  as **reset: 100% left** with the note "reset at 18:20 · no reading since", not the stale
  figure. Gauges, pill, widgets and the resume gate all use this same rule. Window identity from `window_minutes` (300 → session,
  10080 → weekly, else generic), never from `primary`/`secondary` position.
- Codex refill detection *(builder's call)*: a window counts as refilled the first scan
  `now ≥ resets_at` of its latest reading, whatever its `used_percent` — a cutoff can come from
  `rate_limit_reached_type` below 100%. This is safe because only armed sessions whose tail is
  an eligible cutoff ever fire. Needed because no new turns (= no new readings) happen while
  blocked. Also accept a fresh reading whose
  `used_percent` dropped ≥25 (existing `UsageStats.refilledWindows` rule).
- `CodexCutoffDetector`: last meaningful entry is an error event containing "usage limit"
  (or a `token_count` with non-null `rate_limit_reached_type`) → `.eligibleCutoff`;
  `task_complete` → `.cleanlyFinished`; `task_started` without completion → `.running`;
  a trailing user message → `.awaitingUserInput` (terminal Codex has no `user_message`
  event; read `response_item` messages with role `user`).
- Process matching: `LibprocProcessProbe` also returns Codex CLI processes (path contains
  `/.codex/packages/standalone/`, **must have a controlling tty**; excludes anything under
  `ChatGPT.app` and the always-running `~/.codex/packages/app-server-daemon/…/bin/codex`),
  tagged with provider. Planner matches a session only to processes of its own provider.
- `AutoResumePlanner` runs per provider: Claude gate from `UsageStore`, Codex gate from
  `CodexLimits`; each provider has its own resume window, refill cooldown and `lastRefillAt`.
  The armed set is shared (IDs are unique). Only `originator == codex-tui` sessions are armable.
- `SessionSnapshot` gains `codexGauges: [UsageGauge]?` and `codexAsOf: Date?` (optional).
  Widget sessions carry `provider`.

### App

- `SessionMonitor` scans Codex roots alongside Claude's on the same 10-s tick; publishes
  Codex limits too. `AutoResumeCoordinator` runs both plans; notifications say which tool
  ("▶︎ Resumed X (Codex)").
- Brand colours as shared constants (core or a small shared file used by app + widget):
  Claude `#D97757`, Codex `#10A37F`.

### UI

Dropdown — two stacked sections with coloured headers; Codex section only when at least one
Codex transcript exists:
```
● Claude
  Session   ███████░░░  68% left · Fri 14:00
  Weekly    █████░░░░░  51% left · Mon 09:00
  (existing insights unchanged)
────────────────────────────
● Codex                     as of 2h ago
  Weekly    █████████░  96% left · Wed 18:20
  2 running · 1 armed
```
- Menu-bar pill: Claude-only by default. New Settings toggle "Show Codex in menu bar" adds a
  second green pill.
- Sessions window: coloured Claude/Codex tag per row; test-resume works for terminal Codex;
  Codex Desktop rows show "desktop — not resumable".
- Widgets: existing gauge widgets show Claude rings and Codex rings in their colours (Codex
  only when present); session widgets show a coloured dot per row, one list ranked by tokens;
  new single-gauge kind `CodexGaugeWeekly`. Install note: chrono cache purge.

### Notifications (Jakub: "notifications for both, reporting separately")

Codex gets the same limit notifications as Claude — 80/90/100% threshold alerts, the
"refilled" notification and the scheduled reset reminder — reported **separately per tool**:
- Titles name the tool: "Claude · Running on fumes 🔥", "Codex · Tank refilled 🎉".
- Notification identifiers and delivered-threshold state are namespaced by tool
  (today `threshold-<window.id>` and the single `reset-reminder` id would collide, since both
  tools have a "Weekly" window — one tool's reminder would silently replace the other's).
- Settings → two toggles: "Claude limit alerts" (the existing `notificationsEnabled`) and
  "Codex limit alerts" (new, default on; only shown once Codex is present).
- Codex thresholds fire when a reading arrives, i.e. after a Codex turn — inherent to source A.
- Codex refill notification and reset reminder follow the reset rule above (`resets_at` passing).

Not in scope *(Jakub's call: notifications only)*: usage history, sparkline, burn rate and pace
lines stay Claude-only; `history.json` is untouched.

### Logging

Codex decisions log under the existing `autoresume` category, prefixed `codex:`; scan/parse
problems under a `codex` category at `.notice`.

## Risks

- **Cutoff format unverified.** Mitigation: lenient detector + a `.notice` log line dumping the
  last entry type whenever a Codex window is exhausted, so the first real hit can be checked
  and the detector tightened. Docs note the detector as provisional.
- Stale limits: a reading days old is shown with its age; Codex gauges in the widget follow
  the existing 15-min staleness rule only for sessions, not for the limit's own age.
- `continue` in Codex TUI: assumed `write text` (text + newline) submits like in Claude Code;
  verify by hand with the Sessions-window test resume.

## Left to the builder

File layout, exact type names, test fixtures (build them from real local transcripts with
content stripped), how the Settings toggle is worded, widget layout details within the sketches
above, and the order of work. Update CLAUDE.md with a "Codex support" section (sources,
invariants, the unverified cutoff) as part of the work.
