# ClaudeMeter

[![ci](https://github.com/AnywaySolutionsSro/claudemeter/actions/workflows/ci.yml/badge.svg)](https://github.com/AnywaySolutionsSro/claudemeter/actions/workflows/ci.yml)
[![release](https://github.com/AnywaySolutionsSro/claudemeter/actions/workflows/release.yml/badge.svg)](https://github.com/AnywaySolutionsSro/claudemeter/releases/latest)
[![codeql](https://github.com/AnywaySolutionsSro/claudemeter/actions/workflows/codeql.yml/badge.svg)](https://github.com/AnywaySolutionsSro/claudemeter/security/code-scanning)

A tiny native macOS **menu-bar** app that shows your Claude subscription usage at a glance:
**percent remaining** and **time until reset**, read live from Anthropic.

> **Unofficial.** ClaudeMeter is an independent project, not affiliated with or endorsed by
> Anthropic. It relies on undocumented endpoints that may change or stop working at any time.

```
  ┌─────────────┐
  │ 37% · 2h14m │   ← Claude-orange pill in the menu bar
  └─────────────┘
        ▼ (click)
  ┌──────────────────────────┐
  │ ⏲ ClaudeMeter            │
  │ Session (5h)    37% left │
  │ ▓▓▓▓▓▓░░░░  resets 2h14m  │
  │ Weekly          79% left │
  │ ▓▓░░░░░░░░  resets 6d     │
  │ ☑ Start at login         │
  │ Updated 14:46  · Refresh │
  │ Sign out          · Quit │
  └──────────────────────────┘
```

## What it shows

The same numbers Claude Code's `/usage` command reports — the real server-side values, not a
local estimate:

- **Session (5h)** — the rolling 5-hour limit, shown in the menu bar by default.
- **Weekly** — the all-models weekly window.
- **Weekly · Fable** (and any other per-model weekly window Anthropic reports, e.g. Opus or
  Sonnet) — labelled with the server-supplied model name. The one Anthropic flags as currently
  in effect carries a small **limiting** tag. The widget shows a ring per window.

Each shows percent **remaining** and a live **reset countdown**. The menu-bar pill turns
orange under 25 % and red under 10 %.

## Personality & extras

- **Display modes** (Settings ▸ General): `Classic` (% + reset countdown) · `Burn rate`
  (🔥 ETA, shown only when you'd hit the limit before reset) · `Mood face` (😎→💀) ·
  `Fuel gauge` (an E–F dial with a needle) · `Pet` (a cat that sleeps when you're out).
- **Text size** (Settings ▸ General): `Default` / `Large` / `Larger` / `Largest`, for large or
  low-DPI displays. Scales the dropdown, the Sessions window, and the Settings pane's labels;
  the menu-bar pill scales too, up to the fixed height of the macOS menu bar.
- **Burn rate & ETA** — a smoothed least-squares estimate of how fast you're spending
  (% per hour — the API exposes utilization %, not token counts), plus *"2.1× your usual pace"*
  vs. your history.
- **Sparkline** of the current session window, and *"maxed N windows this week"*.
- **Notifications** — nudges at 80 / 90 / 100 % used, and a **"Tank refilled 🎉"** on reset.
- **Cooldown view** when empty, with a one-click **"Remind me when it resets."**
- **Global hotkey** ⌥⌘U toggles the dropdown.
- **Run a Shortcut** when usage drops ≤ 10 % (e.g. flip on a Focus mode).
- **⋯ menu** — quick links to buy more usage / upgrade / help.
- **Claude API spend** *(optional)* — today's and this month's USD spend on the Claude API,
  broken down by model, in the dropdown and as a widget. Needs a Console **Admin API key**
  (`sk-ant-admin01-…`, created at platform.claude.com ▸ Settings ▸ Admin keys) pasted into
  Settings ▸ General, and an **organization** — the Admin API is unavailable to individual
  accounts. This is separate from your subscription login. The key is stored in your Keychain
  and sent only to `api.anthropic.com`; note that a Console admin key carries full
  organization access, as Console keys have no read-only option.

History for burn-rate/sparkline/stats is stored at
`~/Library/Application Support/ClaudeMeter/history.json` (usage numbers only).

## How it works

ClaudeMeter signs in with **its own** OAuth login (one-time, in your browser) and stores the
token in **its own** Keychain item (`com.jakubzak.claudemeter.oauth`). It is fully independent
of Claude Code — it does not read or modify Claude Code's credentials.

- **Usage:** `GET https://api.anthropic.com/api/oauth/usage` with header
  `anthropic-beta: oauth-2025-04-20`. Returns buckets (`five_hour`, `seven_day`,
  `seven_day_opus`, `seven_day_sonnet`), each `{ utilization: 0–100, resets_at: ISO-8601 }`.
- **Auth:** OAuth 2.0 authorization-code + PKCE (S256) against `claude.ai/oauth/authorize`,
  token exchange at `platform.claude.com/v1/oauth/token`, auto-refreshed.

See [`docs/anthropic-endpoints.md`](docs/anthropic-endpoints.md) for the full reverse-engineered
reference. These endpoints are **undocumented**, so the JSON parsing is deliberately lenient and
the UI degrades gracefully if Anthropic changes them.

### Sign-in flow

One click, no copy/paste: ClaudeMeter starts a temporary `http://localhost:<port>/callback`
server, opens the browser to the Claude authorization page, and captures the redirect
automatically. A manual "paste the code" fallback is available if loopback is ever blocked.

## Low footprint by design

- **Bandwidth:** polls the (<1 KB) usage API every **5 minutes**, plus an instant refresh on
  popover-open and on wake-from-sleep. Throttled to ≤1 call / 30 s; backs off on HTTP 429.
- **CPU:** idle cost is effectively zero — the per-second countdown ticker runs **only** while
  the dropdown is open; the bar refreshes on a 30 s timer and on data changes.
- **RAM:** a single lightweight `NSStatusItem`; no Dock icon, no window, no Cmd-Tab entry.
- **Resilience:** the last reading is cached on disk and shown instantly on launch.

## Install

Download `ClaudeMeter.zip` from the
[latest release](https://github.com/AnywaySolutionsSro/claudemeter/releases/latest) — every
release is Developer ID signed and notarized by Apple, so it opens with a normal double-click.

1. Unzip → drag **ClaudeMeter.app** to `/Applications`.
2. Double-click to open.
3. Click **Connect Claude account** → approve in the browser → done.

> Prerequisite: a Claude paid subscription. The app authenticates as your Claude account; it
> bundles no credentials.

**Updates install themselves.** At every launch and once a day the app asks GitHub for the
latest release. A newer one is downloaded in the background and verified (the checksum *and*
Apple's Developer ID signature + notarization of the new bundle) before you hear about it; the
progress bar shows in the dropdown and in Settings → General → Updates. Once it is ready you
get one question, as a notification and a banner: **Restart now** swaps it into `/Applications`
and relaunches; **Remind me in 2 hours** asks again later; **Install on next restart** finishes
the update quietly the next time ClaudeMeter quits or the Mac restarts. *Skip this version*
silences that one release. Settings has the daily-check switch and **Check now**. (Outside
`/Applications` or without write access the offer opens the release page instead.)

## Build from source

Requires the Xcode 26 toolchain (Swift 6.2) and targets macOS 26 (Tahoe).

```bash
swift test                # run the core unit tests
./build.sh                # build dist/ClaudeMeter.app — app + widget (needs Xcode + xcodegen)
./build.sh --install      # build, install to /Applications, launch
./build.sh --spm          # widget-less fallback using only the Swift toolchain
```

### Release (signed + notarized)

```bash
export CODESIGN_ID="Developer ID Application: Jakub Zak (72K9YQF24J)"
export NOTARY_PROFILE="mbx-notary"      # an existing notarytool keychain profile
./build.sh --release                    # signs, notarizes, staples, zips to ~/Desktop
```

`--release` notarizes when the named notary profile exists; otherwise it ships a Developer ID
signed (un-notarized) build that opens via right-click → Open. See
[`docs/release.md`](docs/release.md).

## Project layout

```
Sources/
  ClaudeMeterCore/            Pure, unit-tested core (no AppKit dependency)
    Models/                   UsageBucket, UsageSnapshot, AuthTokens, UsageSample
    Services/                 UsageResponseDecoder, ISODate, PKCE,
                              BurnRate, UsageStats, Personality
    Formatting.swift          percent / countdown helpers
  ClaudeMeter/                Menu-bar app shell
    App/                      main, AppDelegate, UsageStore, AuthModel
    Support/                  Keychain, AccountStore, OAuthLoginService,
                              LoopbackCallbackServer, TokenRefresher, UsageClient,
                              AuthEndpoints, ResponseCache, LoginItem, UsageError,
                              Settings, UsageHistory, NotificationManager,
                              HotKey, ShortcutRunner
    Views/                    MenuBarLabel (mode renderer), MenuContentView,
                              UsageRow, Sparkline
Tests/ClaudeMeterCoreTests/   Decoder, PKCE, formatting tests
Resources/                    AppIcon.icns + make_icon.swift (regenerates the icon)
docs/                         Endpoint reference, release guide, development notes
```

The **core** library holds everything pure and testable (parsing, PKCE, the 5-hour/weekly
math). The **app** target is a thin AppKit + SwiftUI shell. Many small, focused files.

## Privacy

ClaudeMeter talks only to Anthropic (`api.anthropic.com`, `claude.ai`, `platform.claude.com`)
and a localhost callback during sign-in. Tokens live in the macOS Keychain. The last usage
response is cached at `~/Library/Application Support/ClaudeMeter/last-usage.json` (usage numbers
only, no secrets).

## Notes

- The OAuth `client_id` and `anthropic-beta` value are public values extracted from the Claude
  Code CLI; no secrets are embedded.
- Sign out any time from the dropdown (clears the Keychain item).

## License

[MIT](LICENSE)
