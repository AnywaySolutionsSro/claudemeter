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

- **Core** (`ClaudeMeterCore`, pure/TDD, **Swift 6 strict mode**): `TranscriptParser` (lenient
  JSONL → usage records; `<synthetic>` placeholder entries skipped), `SessionAccumulator`
  (incrementally foldable aggregate; headline total = input+output+cacheCreation, cache-reads
  tracked separately; **deduped by `message.id`** — Claude Code writes one JSONL entry per
  content block, each repeating the same id and identical usage, so counting every entry
  inflates totals 2–4x), `RunningResolver` (which sessions are live — ranks by transcript file
  **mtime**, not the last assistant record), `SessionScanner` (actor orchestrating
  discover→parse→resolve→snapshot; **incremental**: caches (mtime, byteOffset, accumulator) per
  file and folds only appended lines, restarting on truncation; canonicalizes session cwds with
  `realpath(3)` to match libproc's kernel-resolved cwds; probes the process table once per scan
  and computes the armable set itself), `TranscriptSource` (scan roots; **subagent transcripts
  under `<sessionId>/subagents/` are discovered with a `parentID`** and their usage folds into
  the parent session), `LibprocProcessProbe` (live CLI cwds via libproc), `SnapshotStore`,
  `SessionSnapshot`.
- **App**: `SessionMonitor` (@MainActor, scans every 10s, publishes), Sessions window
  (`SessionsView` — all sessions + "Active only" toggle), Settings window (`SettingsView`),
  `DesktopAppProbe`.
- **Widget** (`Widget/`, WidgetKit extension): reads the snapshot and shows active sessions.

Scan roots: `~/.claude/projects` (CLI) **and** `~/Library/Application Support/Claude/
local-agent-mode-sessions/**/.claude/projects` (desktop agent/Cowork). Plain desktop chat is
server-side and not trackable.

### Auto-Resume feature (type `continue` into armed sessions after a quota refill)

When the 5-hour window refills, each **armed** session that's sitting at a usage-limit cutoff
gets `continue` typed into its iTerm2 tab. Pipeline:

- **Core** (`AutoResumePlanner`, pure/TDD): given the usage reading + armed set + live processes
  + transcript tails, returns a `ResumePlan` (targets to fire, skips with reasons, updated window).
  Detection is `UsageStats.didRefill` (utilization **drops ≥25** on a 0–100 scale — the only
  reliable reset signal). Eligibility is `CutoffDetector` (`.eligibleCutoff` only — last
  meaningful transcript entry is a `<synthetic>` `isApiErrorMessage` containing "limit").
- **App**: `AutoResumeCoordinator` (@MainActor) runs the planner each ~10s scan and performs the
  side effects — scheduling (staggered), the `ITermDriver` (`NSAppleScript` `write text`, matched
  by `tty`), the tty-reuse defense (`LibprocProcessProbe`), and notifications.

**Retry window (critical).** A refill is detected on a *single* scan, but the gates (live process,
eligible tail) may not all hold at that instant — and a reset during sleep is only seen on wake. So
a refill opens a **5-min retry window** (`resumeWindowSeconds`); every scan re-attempts armed
sessions that haven't fired, and a *failed* attempt un-marks the session so it retries. Without this
the feature was a fragile one-shot that silently missed. Don't revert it to fire-once.

**Diagnosing a miss.** Every decision logs at `.notice` (persisted, unlike `.info`):
`log show --last 6h --predicate 'subsystem == "com.jakubzak.claudemeter" AND category == "autoresume"'`.
A successful resume posts a "▶︎ Resumed X" notification (the only way to tell an auto-`continue`
from a manual one — both write an identical `user:"continue"` transcript entry). The window-close
summary notifies if armed sessions never became eligible.

**`./build.sh` always builds the full app + widget extension** (XcodeGen project from
`project.yml`, dev-team signed). Jakub uses the widget — never install a widget-less build,
or macOS silently deletes his placed widgets. `./build.sh --spm` remains as the widget-less
SwiftPM fallback for toolchains without Xcode; `./build-xcode.sh` is a legacy alias for
`./build.sh --install`. Diagnostics: `ClaudeMeter --dump-sessions`, `ClaudeMeter --snapshot-test`.

## Commands

```bash
swift build -c release          # compile (SwiftPM targets only, quick check)
swift test                      # core unit tests (keep these green)
./build.sh --install            # app + widget → /Applications + launch (dev-team signed)
./build.sh --release            # app + widget, signed + notarized zip to ~/Desktop (env vars below)
./build.sh --notarize           # same, notarization mandatory; zip + .sha256 in dist/ (what CI runs)
./build.sh --spm                # widget-less SwiftPM fallback (no Xcode needed)
swift Resources/make_icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

Release env vars: `CODESIGN_ID="Developer ID Application: Jakub Zak (72K9YQF24J)"` and
`NOTARY_PROFILE="mbx-notary"` (an account-level notarytool keychain profile; reusable across
projects — it authenticates the Apple **team**, not the app). See [docs/release.md](docs/release.md).

**Official releases come from CI, not `--release`:** pushing a tag `vMM.mm.pp` (two-digit,
e.g. `v01.02.03`; `-rcN` = pre-release) runs `.github/workflows/release.yml`, which builds,
notarizes and publishes `ClaudeMeter.zip` to GitHub Releases. Versioning: major = major new
feature, minor = any new feature, patch = any fix. The version comes from the tag — don't
hand-edit `MARKETING_VERSION` in `project.yml` for a release.

**Branch rules:** `main` takes PRs only — the `tests` check must pass (no bypass) and a
code-owner approval is required (repo admins — Jakub — can bypass). Never push to `main`
directly; branch, open a PR, let Jakub merge.

## Conventions

- Swift style per the user's global rules: prefer `let`, value types, small focused files
  (<400 lines), immutability, explicit error handling, no `print()` (use the existing error
  types / `NSLog` sparingly).
- New testable logic goes in **`ClaudeMeterCore`** with tests in `Tests/ClaudeMeterCoreTests`.
- The usage endpoint is undocumented — parse **leniently** (key-by-key via `JSONSerialization`,
  unknown fields ignored, missing buckets become `nil`). Never hard-fail on shape changes.

## Gotchas (learned the hard way)

- **Sending Apple Events (auto-resume → iTerm2) requires BOTH
  `NSAppleEventsUsageDescription` in Info.plist AND the
  `com.apple.security.automation.apple-events` entitlement** (the app builds with the
  hardened runtime). Missing either one makes macOS deny with
  `Not authorized to send Apple events` **silently — the consent prompt is never shown**, so
  the Settings pre-authorize button and every resume just fail. Diagnose with
  `codesign -d --entitlements - /Applications/ClaudeMeter.app` and PlistBuddy; recover a
  recorded denial with `tccutil reset AppleEvents com.jakubzak.claudemeter` (+ app relaunch).
  The consent is requested proactively on first launch / first arm
  (`AppDelegate.requestITermAuthorizationIfNeeded`), and the Sessions window has a per-session
  right-click **test resume** that fires the real pipeline on demand.
- **Keychain re-prompts on every ad-hoc rebuild.** macOS ties "Always Allow" to the code
  signature; an ad-hoc signature changes each build, so `./build.sh --spm` builds re-prompt.
  The default `./build.sh --install` is dev-team signed (stable), so it prompts once. Don't
  "fix" this in code — it's expected for ad-hoc fallback builds.
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
- **Blank chip icon next to ClaudeMeter in the widget gallery sidebar = unresolved macOS 26
  (Tahoe) cosmetic bug; do NOT keep chasing it.** The widget previews and placed widgets render
  their icon fine — only the gallery's left-sidebar app chip is blank. A long investigation
  (2026-06-29) ruled out every data/cache cause: the appex now carries its own `AppIcon`
  (asset catalog + `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` on the `ClaudeMeterWidget` target
  in `project.yml` — keep that, it's correct), the app AND appex icons both resolve perfectly via
  `NSWorkspace.icon(forFile:)` (full 16→1024 rep set), the registration is a single `/Applications`
  entry, and the system IconServices store was purged (`sudo rm -rf
  /Library/Caches/com.apple.iconservices.store`) with chronod fully re-registered (`pluginkit -r`
  then `-a`, `killall chronod`). The chip stayed blank through all of it. **Removing `LSUIElement`
  (to clear the LaunchServices agent flag) does NOT fix it and makes a Dock icon appear** — tried
  and reverted; the runtime `.accessory` policy doesn't reliably suppress the Dock icon once
  `LSUIElement` is gone. Conclusion: accept the blank chip. If you must retry, the only untried lead
  is shipping the icon in the new Tahoe Icon Composer (`.icon`) format — low confidence.
  Verify the icon is actually embedded with `PlistBuddy -c "Print :CFBundleIconName"` on the appex
  Info.plist (should print `AppIcon`) and `assetutil --info <appex>/Contents/Resources/Assets.car`.
- **Missing from the widget gallery / stuck on the placeholder skeleton = duplicate appex
  registrations.** `xcodebuild` leaves the widget bundle ID registered from *two* shadow locations
  besides `/Applications`: (1) a **standalone** `ClaudeMeterWidget.appex` build product under
  `DerivedData/.../Build/Products/{Release,Debug}/`, and (2) the appex **embedded inside every
  stale `ClaudeMeter.app`** that xcodebuild leaves in `DerivedData` and `.build/xcodedd`.
  LaunchServices/chronod discover all of them for the one bundle ID and flip between them; when they
  pick a stale path the timeline provider is never called and the widget either freezes on its
  redacted placeholder or never appears in the gallery at all (the snapshot file is fine).
  Diagnose with `lsregister -dump | grep ClaudeMeterWidget.appex` (lists *every* registered path —
  there should be exactly one, in `/Applications`), plus `pluginkit -mAvvv -i <widgetID>` and `pgrep
  -lf ClaudeMeterWidget.appex` to see which path is running. `build.sh --install` (a) deletes the
  standalone copies, (b) `lsregister -u`'s every stale `ClaudeMeter.app` in DerivedData/`.build`
  (this is what clears the *embedded* registrations — deleting only the standalone appex is not
  enough), and (c) `lsregister -f /Applications/ClaudeMeter.app` + `killall chronod`. Manual
  recovery (lsregister lives at `/System/Library/Frameworks/CoreServices.framework/Frameworks/
  LaunchServices.framework/Support/lsregister`):
  `lsregister -u <each stale ClaudeMeter.app>` → `lsregister -f /Applications/ClaudeMeter.app` →
  `killall chronod`. NB: launching the appex binary by hand to "test" it is useless — it always
  prints `An XPC Service cannot be run directly` regardless of health.

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
