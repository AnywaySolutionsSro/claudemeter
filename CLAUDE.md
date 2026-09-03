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
  tracked separately; **deduped by `message.id`, keeping the LARGEST reading per id** —
  Claude Code writes one JSONL entry per content block, each repeating the same id, so
  counting every entry inflates totals 2–4x; but the entries are NOT identical: the first
  carries the streaming-partial `output_tokens` (often `1`) and a later one the final count,
  so keeping the first entry undercounted output by ~50% on a real corpus (2026-09-03:
  17k of 57k ids differed, 15.8M vs 32.5M output tokens)), `RunningResolver` (which sessions are live — ranks by transcript file
  **mtime**, not the last assistant record), `SessionScanner` (actor orchestrating
  discover→parse→resolve→snapshot; **incremental**: caches (mtime, byteOffset, accumulator) per
  file and folds only appended lines, restarting on truncation; canonicalizes session cwds with
  `realpath(3)` to match libproc's kernel-resolved cwds; probes the process table once per scan
  and computes the armable set itself), `TranscriptSource` (scan roots; **subagent transcripts
  anywhere under `<sessionId>/subagents/` are discovered with a `parentID`** and their usage
  folds into the parent session — walked recursively, because Workflow-tool agents write to
  `subagents/workflows/wf_*/agent-*.jsonl`, which a one-level listing missed: 40% of all
  local transcript tokens went uncounted until 2026-09-03), `LibprocProcessProbe` (live CLI cwds via libproc), `SnapshotStore`,
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
`/usr/bin/log show --last 6h --predicate 'subsystem == "com.jakubzak.claudemeter" AND category == "autoresume"'`
(the full path matters: in zsh `log` is a shell builtin and `log show …` fails with
"too many arguments" — silently if stderr is redirected).
A successful resume posts a "▶︎ Resumed X" notification (the only way to tell an auto-`continue`
from a manual one — both write an identical `user:"continue"` transcript entry). The window-close
summary notifies if armed sessions never became eligible.

### Self-update feature (daily GitHub check, background download, restart prompt)

Flow: check (every launch, throttled to 1 h, then daily + on wake) → a newer in-place-installable
release is **staged without asking** (download + sha256 + `BundleVerifier`, into
`Application Support/ClaudeMeter/Updates/<version>/` with a `staged.json` manifest, so it
survives a reboot) → `.ready` → one prompt (notification `UPDATE_READY` + dropdown banner +
Settings): **Restart now** / **Remind me in 2 hours** (`snoozedUntil`, timer re-notifies) /
**Install on next restart** (`Settings.pendingInstallVersion`; `applicationShouldTerminate` swaps
without relaunch, and `adoptStagedFromDisk()` at the next launch installs + relaunches if the quit
was missed). `UpdatePolicy.disposition(of:current:latest:)` decides what a stage found on disk is
worth (keep / discard / replace by a newer release). A stage is re-verified right before every
install. Download-only installs (`.available`) still open the release page.

- **Core** (pure/TDD): `AppVersion` (`MM.mm.pp`, numeric `Comparable`), `ReleaseDecoder` →
  `ReleaseInfo` (lenient parse of GitHub `releases/latest`; drafts/pre-releases/odd tags → `nil`),
  `Sha256Manifest`, `UpdatePolicy` (24 h cadence, `decide` → upToDate/available/skipped,
  `installMode` → in-place only from `/Applications` or `~/Applications`, not translocated, parent
  writable; otherwise download-only = open the release page).
- **App**: `UpdateService` (@MainActor; first check 60 s after launch, hourly tick that only
  checks when due, wake hook; `UpdateService+Choices` holds remind/defer/quit-time install;
  "Skip this version" persists and discards the stage),
  `GitHubReleaseClient` (unauthenticated API, streaming download), `UpdateInstaller` (download →
  sha256 → `ditto -x -k` → **`BundleVerifier`** → move next to the installed app →
  `replaceItemAt` swap (installed path never empty; old bundle trashed after) → `lsregister -f`
  + `killall chronod` → detached `open -n` with retries + terminate). Diagnostics:
  `ClaudeMeter --update-check` (headless check + download + verify only), `--update-install`
  (headless swap + relaunch; `pkill -x ClaudeMeter` first, run the binary inside
  `/Applications`), and `open -a ClaudeMeter --args --install-update-now` (the **real GUI
  path**: LaunchServices-launched app checks, installs and relaunches without a click).
- **Relaunch must be `open -n` + retry, never a plain `open`.** LaunchServices keeps the
  just-exited process on its running list for a few tens of ms after the kernel reaped it; a
  plain `open` in that window resolves to the dead instance, tries to send it `rapp`
  (reopen), fails with `-600 procNotFound` and launches nothing — the app "crashed and never
  restarted" (2026-08-29, v01.02.00). Diagnose with `/usr/bin/log show --predicate 'process ==
  "CoreServicesUIAgent" AND eventMessage CONTAINS "-600"'` around the relaunch time. UI: `UpdateBanner` in the dropdown,
  `UpdateSettingsSection` in Settings → General; notification with Install/Later actions routed
  through `UpdateNotificationResponder` (the `UNUserNotificationCenter` delegate).
- **Trust gate = `BundleVerifier`**: `SecStaticCodeCheckValidity` against a Developer ID
  requirement pinned to team `72K9YQF24J` + bundle ID, nested code checked, plus Info.plist
  version == release version. A dev-team (`./build.sh --install`) build fails this on purpose —
  only CI releases are ever installed. Logs: category `updater` at `.notice`.
- **End-to-end test recipe:** `MARKETING_VERSION=01.00.00 ./build.sh --install` runs a build that
  believes it's older than the latest release, so the real download/verify/swap/relaunch path can
  be exercised against a genuine notarized release.

### API spend feature (Claude API cost, separate credential)

Subscription usage and **API spend** are different products with different logins. API spend
comes from the **documented** Admin API (`GET /v1/organizations/cost_report`), authenticated
with a Console **Admin API key** (`sk-ant-admin01-…`) held in ClaudeMeter's own Keychain item
`com.jakubzak.claudemeter.adminkey`.

- **Core** (pure/TDD): `AdminKey` (prefix validation), `CostReportDecoder` → `ApiSpendSnapshot`
  (`CostDay` / `ModelSpend`), `Formatting.usd`.
- **App**: `AdminKeyStore`, `CostClient` (paginating), `ApiSpendStore` (@MainActor, 15-min tick
  + dropdown-open refresh throttled to 5 min), `ApiSpendSection`, `ApiSettingsSection`.
- **Widget**: kind `ClaudeApiSpend` (`Widget/ApiSpendWidget.swift`), reading `api-spend.json`
  from its own container — the app cannot deliver into the App Group container a sandboxed
  widget can read, same constraint as `snapshot.json`. Kept a **separate file** because the two
  producers run on different cadences and would race on one.

**`amount` is a decimal string in CENTS, not dollars** — `"103.1554"` is $1.03. Reading it as
dollars overstates spend 100x. The division lives in `CostReportDecoder` alone, pinned by a
regression test. **`limit` defaults to 7 daily buckets** regardless of the date range and
silently truncates a month query, so `CostClient` always sends it and follows
`has_more`/`next_page`. Input and output arrive as separate rows per day and must be summed.

Buckets are UTC-aligned; we present UTC days so figures match the invoice, which means "Today"
can look off late in a local evening. The Admin API needs an **organization** — individual
accounts get nothing. There is **no documented balance endpoint**; when one ships it becomes
another field on `ApiSpendSnapshot`.

**The Cost API reports COMPLETED UTC days only.** `ending_at` is silently clamped to the start
of the current day, and a range that then collapses to zero length is rejected with **HTTP 400
"Invalid date range: ending date must be after starting date"** — a misleading message, since
the dates you sent really are in order. Verified 2026-09-01: `Aug 30 → Sep 02` returns only the
Aug 30 and Aug 31 buckets. Consequences: **there is no "today" figure** (the UI shows
*Yesterday* = most recent completed day), and month-to-date on the **1st of a month** is an
empty range that 400s. `CostWindow.trailing` spans from the start of the **previous** month (which
also feeds the "Last month" row and makes the range structurally non-empty), and `ApiSpendSnapshot.monthToDateUSD(now:)` / `previousMonthUSD(now:)` filter that window by UTC
month. A ~62-day span exceeds the API's **31-bucket cap**, so pagination is mandatory, not
optional — verified: Jul 1 → Sep 1 returns July, then August.

**Never call `AdminKeyStore.load()` from a SwiftUI body.** A Keychain read that returns the
secret (`kSecReturnData: true`) is authorization-gated and makes macOS prompt for the login
password; a **metadata-only** query is not. `MenuContentView` re-evaluates every second (the
countdown ticker), so a `hasKey` that loaded the secret produced a password prompt per second.
`hasKey` uses `Keychain.exists` (metadata only) and `ApiSpendStore` caches it in a `@Published`
property, mirroring how `AuthModel` caches `state` instead of re-reading the Keychain.

**The widget's bundle ID is `com.jakubzak.claudemeter.ClaudeMeterWidget`**, not
`…claudemeter.widget`. Always build the inbox path from `SessionMonitor.widgetBundleID` — a
hardcoded guess fails **silently**, because the non-sandboxed app cheerfully creates the wrong
container directory and writes there, so the delivery "succeeds" while the widget reads an
empty container forever. Verify with
`ls ~/Library/Containers/com.jakubzak.claudemeter.ClaudeMeterWidget/Data/Documents/` — both
`snapshot.json` and `api-spend.json` must be there.

**A NEW widget kind needs `~/Library/Caches/com.apple.chrono` purged.** Adding a widget to
`ClaudeMeterWidgetBundle` is not picked up by the documented recovery for *sizes*
(`pluginkit -r`/`-a` + `lsregister -f` + `killall chronod`) — chronod caches the enumerated
**descriptors** on disk, and that cache survives all of it, so the gallery keeps showing the old
set while the binary plainly contains the new one (2026-09-01, `ClaudeApiSpend`). Recovery:

```bash
killall chronod; rm -rf ~/Library/Caches/com.apple.chrono
pluginkit -r <appex>; pluginkit -a <appex>; killall chronod
```

Confirm with the kinds chronod actually knows — this is the diagnostic that ends the guessing:

```bash
/usr/bin/log show --last 2m --predicate 'process == "chronod"' \
  | grep -oE "ClaudeMeterWidget:[A-Za-z]+" | sort -u
```

Also worth clearing: the self-updater leaves `~/.Trash/ClaudeMeter.app.previous` registered with
LaunchServices, and `lsregister -u` cannot remove it once the file is gone. It appeared harmless
here (`pluginkit` still resolved to `/Applications`), but it is noise when diagnosing.

**The admin key stays in the LEGACY login keychain, and that is a known, accepted
exposure.** `AdminKeyStore` tries the data-protection keychain first
(`kSecUseDataProtectionKeychain` + `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) and falls
back to the login keychain. The fallback is **not optional**: the data-protection keychain
returns **-34018 `errSecMissingEntitlement`** for this app (verified 2026-09-01, on a dev
build that *does* carry `com.apple.application-identifier`), and a Developer ID release build
has no provisioning profile at all — so a data-protection-only store would work on a dev
machine and silently make the key unsaveable in every shipped build. Which store won is logged at `.notice`, category
`adminkey`.

**This is a decided trade-off, not an open bug — don't reopen it.** The key lives in
`login.keychain-db`, which Time Machine and Migration Assistant *do* carry (so it survives a
machine migration and the same signed app can still read it — keychain ACLs follow the code
signature, not the hardware). Jakub reviewed and accepted this on 2026-09-01: the exposure is
the macOS norm for a Developer ID app, and **Anthropic's own Claude Code and Claude desktop
app store their credentials in the same login keychain on the same machine**, as do Chrome,
Arc, VS Code and NordVPN. Closing it would need the `keychain-access-groups` entitlement plus
the Keychain Sharing capability on the App ID — feasible (the app already embeds a
provisioning profile for App Groups) but not worth it for this. If you want to reduce risk,
reduce the credential's *privilege* (a service-account key, or an expiring key), not its
storage tier.

**Never surface `UsageError` from the Cost API path.** Its copy is about the OAuth
subscription login ("Run `claude` and sign in"), a different credential; showing it for a
rejected admin key told users to re-authenticate something that was never broken. Cost paths
throw `CostError` (`invalidAdminKey` / `notAnOrganization` / `keyUnreadable` /
`unreadableReport` / …).

**A degraded cost report is an error, not a number.** `CostAmount.parse` rejects anything that
is not a complete decimal — `Decimal(string:)` alone **truncates** (`"1,234.5678"` → `1`, a
1000x understatement) — and accepts a JSON number as well as a string, so a shape change
degrades to a correct reading instead of a confident $0.00. `CostReportDecoder` counts skipped
rows/buckets, `CostPageAccumulator` dedupes days by `start` and refuses a repeated cursor or an
exhausted page budget, and `CostClient` throws `unreadableReport` if anything was skipped. The
previous good snapshot is kept; the cache and widget file are never overwritten with a partial
or zeroed reading.

**Every figure ships with its age.** `ApiSpendStore` publishes `lastUpdated` and `statusNote`
(mirroring `UsageStore.present(_:)`), the dropdown shows the fetch time and marks >24 h stale,
and the widget renders "as of …" plus `—` rather than `$0.00` when its snapshot predates the
month asked about. `Formatting.usd` rounds **half-up** (to match the invoice, not
`NumberFormatter`'s half-even default) and renders `<$0.01` for real sub-cent spend.

**Don't seed the key with `/usr/bin/security`.** An item created by another binary fails the
app's code-signature ACL, so `AdminKeyStore.load()` silently returns nil and the feature looks
dead with no log line. Paste the key in Settings so the app creates the item itself. Logs:
category `apispend` at `.notice` (failures only).

**`./build.sh` always builds the full app + widget extension** (XcodeGen project from
`project.yml`, dev-team signed). Jakub uses the widget — never install a widget-less build,
or macOS silently deletes his placed widgets. `./build.sh --spm` remains as the widget-less
SwiftPM fallback for toolchains without Xcode; `./build-xcode.sh` is a legacy alias for
`./build.sh --install`. Diagnostics: `ClaudeMeter --dump-sessions`, `ClaudeMeter --snapshot-test`.

## Commands

```bash
swift build -c release          # compile (SwiftPM targets only, quick check)
swift test                      # core unit tests (keep these green)
swiftformat .                   # format (config: .swiftformat); CI runs `swiftformat . --lint`
swiftlint --strict              # lint (config: .swiftlint.yml); every warning fails CI
scripts/coverage-gate.sh        # tests + ClaudeMeterCore line coverage >= 80% (what CI runs)
./build.sh --install            # app + widget → /Applications + launch (dev-team signed)
./build.sh --release            # app + widget, signed + notarized zip to ~/Desktop (env vars below)
./build.sh --notarize           # same, notarization mandatory; zip + .sha256 in dist/ (what CI runs)
./build.sh --spm                # widget-less SwiftPM fallback (no Xcode needed)
swift Resources/make_icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

Release env vars: `CODESIGN_ID="Developer ID Application: Jakub Zak (72K9YQF24J)"` and
`NOTARY_PROFILE="mbx-notary"` (an account-level notarytool keychain profile; reusable across
projects — it authenticates the Apple **team**, not the app). See [docs/release.md](docs/release.md).

**Releases are automatic (`.github/workflows/release.yml`):** every PR merged into `main`
whose title starts with `feat` (minor) or `fix`/`perf` (patch) is built, notarized and
published to GitHub Releases as `vMM.mm.pp` (two-digit, e.g. `v01.02.03`). Other types
(`ci`, `docs`, `build`, `chore`, `refactor`, `test`, `style`) merge without a release.
**Majors are manual only** (Actions → release → Run workflow → bump: major). The version
comes from the plan (`scripts/release-plan.sh`) — don't hand-edit `MARKETING_VERSION` in
`project.yml` for a release, and never push `v*` tags by hand. See [docs/release.md](docs/release.md).

**Branch rules:** `main` takes squash-merged PRs only — the `ci` jobs `pr-title`, `tests`,
`lint`, `build-app` and `scripts` must pass (no bypass) and a code-owner approval is required
(repo admins — Jakub — can bypass). **PR titles must be Conventional Commits subjects**
(`type(scope): summary`, types listed above; `!`/BREAKING CHANGE is refused) because the
title becomes the commit on `main` and decides the release. **Name branches
`<type>/<short-topic>`** with the same type you'll put in the PR title (`feat/`, `fix/`,
`perf/`, `ci/`, `docs/`, `chore/`, `refactor/`, `test/`), so the branch already says whether
the merge releases and how; the title is what actually decides — keep them consistent. Never
push to `main` directly; branch, open a PR, let Jakub merge.

**Release notes (required for every `feat`/`fix`/`perf` PR; the `pr-title` check enforces
it).** Nobody works on ClaudeMeter without an AI agent, so **the agent doing the work writes
the release notes** — in the PR body, as a `## Release notes` section of 1–3 bullets, each
starting with an emoji. `release.yml` (`scripts/release-notes.sh`) turns the bullets of all
PRs since the previous release into the GitHub release body (grouped ✨ New / 🐛 Fixes /
⚡ Faster, `(#PR)` appended), and the app shows them in the update prompt next to the notes
of the version the user is on — so this is customer-facing copy, not a changelog:
- Warm, plain, human: say what the person gains or what stopped hurting, in their words
  (“✨ The dropdown now shows which version you're running”), never internals
  (“refactor UpdateService state machine”), file names, or PR jargon.
- One idea per bullet, sentence case, no trailing period needed, ≤ ~90 characters.
- Emoji vocabulary: ✨ new · 🐛 fix · ⚡ faster/lighter · 🎨 look & feel · 🔒 privacy/security ·
  🧹 tidy-up · ⚠️ behaviour change worth knowing · 🔄 updates/releases.
- Non-releasing PRs (`ci`, `docs`, …) don't need the section (they never reach a release
  body); a releasing PR without bullets falls back to its emoji-prefixed title.
- Preview locally: `scripts/release-notes.sh v01.03.00 v01.04.00` (uses `gh`).

**Quality gates (CI = local):** zero compiler warnings (`-warnings-as-errors` in both
`swift build` and the Xcode build), `swiftlint --strict`, `swiftformat --lint`, core line
coverage ≥ 80%, shellcheck + actionlint. Run `swiftformat . && swiftlint --strict &&
scripts/coverage-gate.sh` before pushing. Prefer fixing a violation over disabling a rule; a
`swiftlint:disable` must be scoped (`:next` or a `disable`/`enable` pair) with a reason.
CodeQL runs on `main` weekly as an advisory scan (Security tab).

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
  The server binds **127.0.0.1 only** (an `NWListener` without `requiredLocalEndpoint` listens
  on every interface), accepts a redirect only when its `state` matches the one this login
  sent (anything else gets a 400 and the listener keeps waiting), and times out after 10 min.
- **Auto-resume compares against `UsageStore.snapshotForRefillDetection`, not the raw
  snapshot.** The launch-time on-disk cache can be days old; comparing the first live fetch
  against it looked like a refill, fired `continue` into stale sessions and burned the 1-h
  refill cooldown so a genuine refill minutes later was ignored. A cached reading counts only
  while younger than 5 h (an update relaunch, a quick restart). The planner also skips armed
  sessions that are no longer `.running` — their cwd may now host a *different* session's
  process — and the coordinator holds its baseline while the weekly window is exhausted, so a
  5-h refill under a weekly cutoff doesn't type `continue` into a wall every 5 hours.
- **Widget reloads are budgeted (~40–70/day for a background app).** `SessionMonitor.publish`
  writes the snapshot file on every scan (the widget reads `generatedAt` to detect a dead
  app) but calls `reloadAllTimelines()` only when the
  running/armed/gauge structure changes, or at most every 5 min for token-count-only changes.
  Reloading on every 10 s scan while a session streamed (measured ~2,400/day) got the widget
  throttled and frozen. The widget marks a snapshot older than 15 min as stale ("as of …",
  nothing armable) rather than showing dead sessions as live.
- **`AdminKeyStore.clear()` must tolerate the data-protection delete failing.** In a
  Developer ID build that delete returns -34018 even when nothing is stored there; a thrown
  error made "Remove" impossible in every shipped build. The post-delete `hasKey` check is
  what guarantees the key is really gone.

- **Transcript `cwd` hops into `.claude/worktrees/` are NOT moves.** Worktree tools (EnterWorktree,
  agents with worktree isolation) stamp `<repo>/.claude/worktrees/<name>` as the `cwd` of records
  — thousands of them, interleaved with `<repo>` — while the CLI process keeps its cwd at
  `<repo>`. Following the newest record's cwd made the live session unmatchable for minutes at a
  time, so an *ended* 3-minute session in the same folder took the "running" slot in the widget
  with its own model and token count (2026-09-03: "mbx 90K fable-5" instead of the real 810K
  fable-5-1 session). `ClaudeWorktree.isHop` keeps `lastCwd` on the real folder; a session that
  *starts* inside a worktree still keeps the worktree path, and a real `cd` elsewhere is still
  followed. Diagnose with the transcript's cwd transitions vs `lsof -a -p <pid> -d cwd`.
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
