# API spend tracking — design

**Date:** 2026-08-30
**Status:** approved, ready for implementation

## Problem

ClaudeMeter today reports only *subscription* usage (the undocumented `/api/oauth/usage`
endpoint: % utilization + reset countdown). Jakub also spends against the **Claude API**,
billed separately under a Console organization, and has no glanceable view of it.

## Scope

**In:** daily USD spend for the org — today, month to date, per model — in the dropdown, in
Settings (credential entry), and as a home-screen widget.

**Out (deliberately):**

- **Credit balance.** Anthropic exposes **no documented endpoint** for the prepaid balance;
  only the Console UI shows it, via cookie-authenticated internal routes. Reverse-engineering
  those is a materially worse bet than the subscription endpoint (which the CLI itself depends
  on). When a balance endpoint ships, it slots into `ApiSpendSnapshot` as one more field.
- **`usage_report/messages`.** `cost_report` already carries the per-model breakdown the UI
  needs. Token counts, cache-hit efficiency and 1m/1h granularity are a later extension.

## Source of truth

`GET https://api.anthropic.com/v1/organizations/cost_report`

- Auth: `x-api-key: sk-ant-admin01-…` (Console **Admin API key**), `anthropic-version: 2023-06-01`.
- Documented and supported — unlike the subscription endpoint. Polling ≤ 1/min is sanctioned.
- Data appears ~5 minutes after the API request completes.
- Requires an **organization**; individual accounts get nothing.

### Verified response shape (captured 2026-08-30 against the real org)

```json
{"starting_at":"2026-08-21T00:00:00Z","ending_at":"2026-08-22T00:00:00Z",
 "results":[{"currency":"USD","amount":"103.1554","workspace_id":null,
   "description":"Claude Sonnet 5 - Input Tokens","cost_type":"tokens",
   "context_window":"0-200k","model":"claude-sonnet-5","service_tier":"standard",
   "token_type":"uncached_input_tokens","inference_geo":"global"}]}
```

Envelope: `{"data":[…],"has_more":false,"next_page":null}`.

### Two verified gotchas (both cost real debugging time on 2026-08-30)

1. **`amount` is a decimal string in CENTS, not dollars.** `"103.1554"` is **$1.03**.
   Back-solved against token counts, the cents reading yields exactly $2/MTok input and
   $10/MTok output; the dollars reading yields nonsense. Reading it naively overstates spend
   **100×**. The conversion lives in exactly one place (`CostReportDecoder`) and is pinned by
   a regression test.
2. **`limit` defaults to 7 daily buckets regardless of the date range**, silently truncating.
   A 31-day query without `limit` returns only the first 7 days and can look like "no data at
   all". Always send `limit` explicitly and follow `has_more` / `next_page`.

Also: input and output arrive as **separate rows per day** (split by `token_type`) and must be
summed. `api_key_id` is `null` for Console playground usage.

## Architecture

### Core (`ClaudeMeterCore`) — pure, TDD, no AppKit

| Type | Responsibility |
|---|---|
| `AdminKey` | Validates non-empty + `sk-ant-admin01-` prefix. Rejects a malformed paste up front rather than surfacing a confusing 401 later. |
| `CostReportDecoder` | Lenient `JSONSerialization` parse, key-by-key, unknown keys ignored (same contract as `UsageResponseDecoder`). **Sole owner of the cents→dollars conversion.** |
| `ApiSpendSnapshot` | `Codable`. `[CostDay]` plus derived `today`, `monthToDate`, `byModel`. Shared with the widget target. |

**Dates.** Buckets are UTC-aligned; a local Bratislava day straddles two of them. We present
UTC-aligned days so the app agrees with the invoice and with Console, at the cost of "Today"
reading slightly off late at night. Accepted deliberately.

### App (`ClaudeMeter`)

- `Support/AdminKeyStore` — own Keychain item `com.jakubzak.claudemeter.adminkey`, mirroring
  `AccountStore`. Exposes `hasKey` / `save` / `clear`; **never vends the key to a view**.
- `Support/CostClient` — explicit `limit`, follows pagination, sets
  `User-Agent: ClaudeMeter/<version>`, maps 401 / 403 / 429 to typed errors.
- `App/ApiSpendStore` — `@Published` snapshot, disk cache via the existing `ResponseCache`.
  Refresh on dropdown-open throttled to ≥5 min, plus a 15-minute background tick. Daily-
  granularity data landing ~5 min behind makes 30 s polling pure waste.
- `Views/ApiSpendSection` (dropdown), `Views/ApiSettingsSection` (Settings).

### Widget

A **fifth widget kind**, `ClaudeApiSpend`, added to `ClaudeMeterWidgetBundle`.
`.systemSmall` only for v1, matching the existing gauge widgets: month-to-date as the headline,
today beneath it.

**Delivery follows the established constraint:** a sandboxed widget cannot read the
non-sandboxed app's App Group container, so `ApiSpendStore` writes into the widget's *own*
container Documents — a **separate `api-spend.json`**, not the existing `snapshot.json`.
Separate files because the producers (`SessionMonitor` at 10 s, `ApiSpendStore` at 15 min) and
cadences differ; sharing one file would race. The widget performs no network and no Keychain
access — it only reads the delivered file.

**Deployment gotcha (pre-existing, see CLAUDE.md):** adding a widget kind requires
re-registering the appex (`pluginkit -r` then `-a`, `killall chronod`) before it appears in the
gallery. `build.sh --install` already clears stale registrations. The blank gallery-sidebar
chip on Tahoe is a known cosmetic bug — do not chase it.

## Settings UX

`SecureField`, with inline instructions: create at **Console → Settings → Admin keys**,
requires the admin role, shown only once, starts with `sk-ant-admin01-`. A **Verify** button
calls `/v1/organizations/me` and on success replaces the field with `✓ <org name>`, proving the
credential end to end and confirming which org is being read. After saving, the key is never
rendered back — only replaced or cleared.

The help text states plainly that **a Console admin key carries full organization access**
(member management included); Console keys have no read-only variant and no scope picker. This
is a real trade for displaying a spend number, and the user should see it stated.

## Failure behaviour

| Condition | Behaviour |
|---|---|
| No key set | Dropdown section **hidden entirely** — no change for users not tracking API spend |
| 401 invalid key | One row: "API key invalid — open Settings" |
| 403 / individual account | Explains the organization requirement |
| 429 | Serve cache, honour `Retry-After` (as `UsageStore` already does) |
| Network down | Serve last cached snapshot with its timestamp |

## Testing

Core line coverage ≥ 80% (CI gate). Fixtures cover: the cents conversion, empty `results`
buckets, multi-row day summing, pagination with `has_more`, and malformed/unknown-key input.

**Fixtures are synthetic**, hand-written to match the verified shape — including the literal
`"103.1554"` value. The repository is public; real spend figures for the org stay out of it.

## Security

- Key in its own Keychain item, never logged, never rendered back, never sent anywhere but
  `api.anthropic.com`.
- The widget never sees it.
- `AdminKey` prefix validation rejects malformed input early.

## Release notes

- ✨ Track your API spend right in the dropdown — today and month to date, broken down by model
- ✨ Add a Console admin key in Settings to turn on API cost tracking
- ✨ New widget for API spend, so the month's total sits on your desktop
