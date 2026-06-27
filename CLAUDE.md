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
