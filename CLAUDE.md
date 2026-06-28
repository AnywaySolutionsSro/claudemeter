# CLAUDE.md

Guidance for AI agents working in this repository.

## What this is

ClaudeMeter is a native macOS **menu-bar app** (Swift, SwiftPM — no Xcode project) that shows
Claude subscription usage (% remaining + reset countdown) by calling Anthropic's undocumented
usage endpoint, authenticated via the app's own OAuth login. See [README.md](README.md) for the
product overview and [docs/anthropic-endpoints.md](docs/anthropic-endpoints.md) for the API
reference.

## Architecture

Two SwiftPM targets, strict separation:

- **`ClaudeMeterCore`** — pure, no AppKit, fully unit-tested. Models (`UsageBucket`,
  `UsageSnapshot`, `AuthTokens`), parsing (`UsageResponseDecoder`, `ISODate`), crypto (`PKCE`),
  formatting. **Put logic here** so it can be tested without a GUI.
- **`ClaudeMeter`** — the AppKit + SwiftUI shell. Networking, Keychain, the status item, the
  popover, view-models (`UsageStore`, `AuthModel`). No business logic that could live in core.

Data flow: `AccountStore` (token in own Keychain item) → `UsageClient` (`GET /api/oauth/usage`)
→ `UsageResponseDecoder` → `UsageSnapshot` → `UsageStore` (`@Published`) → `MenuBarLabel`
(NSImage pill) + `MenuContentView` (dropdown).

### Live Sessions feature (local token usage per Claude Code session)

A second subsystem reads local Claude Code transcripts and shows per-session token usage:

- **Core** (`ClaudeMeterCore`, pure/TDD): `TranscriptParser` (lenient JSONL → usage records),
  `SessionAggregator` (fold → `SessionUsage`; headline total = input+output+cacheCreation,
  cache-reads tracked separately), `RunningResolver` (which sessions are live), `SessionScanner`
  (actor orchestrating discover→parse→resolve→snapshot), `TranscriptSource` (scan roots),
  `LibprocProcessProbe` (live CLI cwds via libproc), `SnapshotStore`, `SessionSnapshot`.
- **App**: `SessionMonitor` (@MainActor, scans every 10s, publishes), Sessions window
  (`SessionsView` — all sessions + "Active only" toggle), Settings window (`SettingsView`),
  `DesktopAppProbe`.
- **Widget** (`Widget/`, WidgetKit extension): reads the snapshot and shows active sessions.

Scan roots: `~/.claude/projects` (CLI) **and** `~/Library/Application Support/Claude/
local-agent-mode-sessions/**/.claude/projects` (desktop agent/Cowork). Plain desktop chat is
server-side and not trackable.

Two builds: **`./build.sh`** = SwiftPM menu-bar app (no widget). **`./build-xcode.sh`** =
XcodeGen project (`project.yml`) building app + widget extension, signed with the dev team.
Diagnostics: `ClaudeMeter --dump-sessions`, `ClaudeMeter --snapshot-test`.

## Commands

```bash
swift build -c release          # compile
swift test                      # core unit tests (keep these green)
./build.sh --install            # build + install to /Applications + launch (ad-hoc signed)
./build.sh --release            # signed + notarized zip to ~/Desktop (see env vars below)
swift Resources/make_icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

Release env vars: `CODESIGN_ID="Developer ID Application: Jakub Zak (72K9YQF24J)"` and
`NOTARY_PROFILE="mbx-notary"` (an account-level notarytool keychain profile; reusable across
projects — it authenticates the Apple **team**, not the app). See [docs/release.md](docs/release.md).

## Conventions

- Swift style per the user's global rules: prefer `let`, value types, small focused files
  (<400 lines), immutability, explicit error handling, no `print()` (use the existing error
  types / `NSLog` sparingly).
- New testable logic goes in **`ClaudeMeterCore`** with tests in `Tests/ClaudeMeterCoreTests`.
- The usage endpoint is undocumented — parse **leniently** (key-by-key via `JSONSerialization`,
  unknown fields ignored, missing buckets become `nil`). Never hard-fail on shape changes.

## Gotchas (learned the hard way)

- **Keychain re-prompts on every ad-hoc rebuild.** macOS ties "Always Allow" to the code
  signature; an ad-hoc signature changes each build, so `./build.sh --install` re-prompts.
  A stable **Developer ID** (notarized) build prompts once and never again. Don't "fix" this in
  code — it's expected for ad-hoc dev builds.
- **Agent apps (LSUIElement) have no menu bar**, so Cmd+V/C/X/A don't reach text fields. We
  install a minimal Edit menu in `AppDelegate.installEditMenu()`. Don't remove it.
- **`.transient` popovers don't auto-close for a background agent** (the window never becomes
  key). We add a global mouse-down monitor in `AppDelegate` to close on outside click. Keep it.
- **The menu-bar label must redraw on data changes**, not just on a timer — `AppDelegate`
  subscribes to `UsageStore`/`AuthModel` `objectWillChange` (Combine). Without this the pill is
  stale/blank until the next 30 s tick. Also redraw via `effectiveAppearance` so light/dark
  resolves correctly.
- **`resets_at` is an ISO-8601 string with microseconds** (`...59.398499+00:00`). Swift's
  `ISO8601DateFormatter` only handles milliseconds, so `ISODate` strips fractional seconds. The
  CLI's own doc comment wrongly calls it epoch seconds — the decoder accepts both, but real data
  is the string.
- **Rate limiting (HTTP 429) is easy to hit** when iterating. `UsageStore` throttles to ≤1
  call/30 s, backs off honoring `Retry-After`, and serves the on-disk cache. Don't poll more
  aggressively.
- **OAuth loopback redirect** (`http://localhost:<port>/callback`) is what enables the one-click
  login (`LoopbackCallbackServer`). The manual paste flow uses the hosted callback instead.

- **Claude Code CLI processes are matched by executable PATH, not name.** The CLI runs
  versioned binaries (`~/.local/share/claude/versions/<v>`), so `proc_name` returns the version
  string (e.g. `2.1.195`), never `claude`. `LibprocProcessProbe` matches `proc_pidpath` containing
  `/claude/versions/` or `/claude-code/` (excluding `ClaudeMeter` itself).
- **A sandboxed widget CANNOT read what the non-sandboxed app writes into the App Group
  container** (`NSCocoaError 257 / EPERM`) — true for both raw files and `UserDefaults(suiteName:)`.
  The app can't be sandboxed (it needs libproc + `~/.claude` access), so the snapshot is delivered
  into the **widget's own container** (`~/Library/Containers/<widgetID>/Data/Documents/snapshot.json`),
  which the widget always reads. See `SessionMonitor.widgetInboxURL()`.
- **Widget supported sizes are cached by `chronod`.** After changing `.supportedFamilies`, a plain
  reinstall won't show new sizes — re-register the appex (`pluginkit -r` then `-a`), `killall
  chronod`, and remove/re-add the widget.
- **The widget only has data while the app is running** (the app is the scanner). It refreshes on
  WidgetKit's timeline (~5 min) plus immediate `WidgetCenter.reloadAllTimelines()` when the
  published snapshot changes.

## How the endpoints were obtained

By `strings`-grepping the installed Claude Code binary
(`~/.local/share/claude/versions/<v>`), not from public docs. If something breaks after a Claude
Code update, re-grep that binary for the new shape. Details + exact greps are in
[docs/development-notes.md](docs/development-notes.md).

## Do not

- Read or write Claude Code's `Claude Code-credentials` Keychain item (we deliberately moved off
  that to avoid cross-app prompts and refresh-token rotation risk).
- Commit secrets. The bundled `client_id`/beta header are public; real tokens live only in the
  Keychain.
