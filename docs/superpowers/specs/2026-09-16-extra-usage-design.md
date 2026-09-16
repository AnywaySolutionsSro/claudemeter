# Extra usage — design

**Date:** 2026-09-16
**Status:** approved in brainstorming; awaiting spec review

## Summary

Surface the **extra usage** (paid overage) allowance that Claude subscriptions bill on top of
the plan: how much of it has been spent this month, how close it is to the monthly cap, and a
one-click hand-off to claude.ai to turn it on, raise the cap, or top it up.

ClaudeMeter **never writes** to the billing API. Every action that changes money opens
`https://claude.ai/settings/usage` in the browser.

## Motivation

`GET /api/oauth/usage` — the single request `UsageStore` already makes every 30 seconds —
returns the complete extra-usage picture, and ClaudeMeter discards it. On the author's account
today that is €75.09 of a €110.00 monthly cap, 68% used, with no indication anywhere in the app
that paid spend is happening at all. The first signal a user gets today is a card charge.

## Non-goals

- **No writes of any kind.** No enable/disable toggle, no monthly-limit editor, no credit
  purchase, no auto-reload configuration. See "Why links, not writes" below.
- **No menu-bar pill change.** The pill stays terse; extra usage lives in the dropdown.
- **No spend history, sparkline, or burn-rate projection.** Deferred — `UsageHistory` /
  `UsageSample` make it cheap to add later if the plain figure proves insufficient.
- **No attribution of spend to individual Claude Code sessions.** The API never says which
  session spent what; any such figure would be an estimate presented as a fact.

## Data source

No new endpoint, no new credential, no extra network traffic. Two overlapping representations
arrive in the body `UsageResponseDecoder` already parses:

```json
"extra_usage": {
  "is_enabled": true, "monthly_limit": 11000, "used_credits": 7509.0,
  "utilization": 68.26363636363637, "currency": "EUR", "decimal_places": 2,
  "disabled_reason": null, "user_disabled": false, "spend_limit_reached": false,
  "credits_ever_enabled": true, "daily": null, "weekly": null
},
"spend": {
  "used":  { "amount_minor": 7509,  "currency": "EUR", "exponent": 2 },
  "limit": { "amount_minor": 11000, "currency": "EUR", "exponent": 2 },
  "percent": 68, "severity": "normal", "enabled": true, "disabled_reason": null,
  "cap": { "money": { "amount_minor": 11000, … }, "credits": null },
  "balance": null, "auto_reload": null,
  "disclaimer": "Usage credits cover you when you hit your plan limits. [Learn more](…)",
  "can_purchase_credits": false, "can_toggle": false
}
```

**Precedence: `spend` wins, `extra_usage` is the fallback.** `spend` is the newer, structured
block — money carries its own currency and exponent, and it adds the capability flags. This
mirrors the rule `limits[]` already has over the legacy `seven_day_<model>` buckets. Both agree
today (7509/11000, 68%); when they disagree, the newer block is the truth.

`can_toggle` and `user_disabled` do **not** appear anywhere in the Claude Code binary
(2.1.266) — they are server-side additions newer than the client, and what gates them is
unverified. Only `can_purchase_credits` is consumed, and only to decide whether to show a buy
affordance.

## Model

```swift
/// An amount of money as the usage API reports it: minor units plus the currency's
/// own exponent. NEVER assume 2 — JPY is 0 — and never assume USD.
public struct Money: Equatable, Sendable {
    public let amountMinor: Int
    public let currency: String   // ISO 4217
    public let exponent: Int      // decimal places
}

public struct ExtraUsage: Equatable, Sendable {
    public let isEnabled: Bool
    public let used: Money
    public let limit: Money?        // nil = no monthly cap set
    public let utilization: Double? // 0–100, server-computed; nil without a cap
    public let capReached: Bool
    public let disabledReason: String?
    public let canPurchase: Bool
}
```

`UsageSnapshot` gains `extraUsage: ExtraUsage?`.

### Two parsing rules that are not negotiable

**Money is minor units with a server-supplied exponent.** `{amount_minor: 7509, currency:
"EUR", exponent: 2}` is €75.09. Nothing hardcodes 2, nothing assumes USD. This is the same
class of bug as the Cost API's cents-vs-dollars trap (CLAUDE.md), which overstated spend 100x;
the conversion lives in one place and is pinned by a regression test.

**A half-read figure is `nil`, not zero.** If `amount_minor`, `currency` and `exponent` do not
*all* parse, `ExtraUsage` is `nil`: the section hides and the last good cached value stands.
ClaudeMeter must never render a confident €0.00 over a parse failure — again the Cost API rule
("a degraded cost report is an error, not a number").

## Presentation

### Dropdown

A section below the plan windows, sibling to API Spend. Five states:

| State | Condition | Renders |
|---|---|---|
| Hidden | neither `spend` nor `extra_usage` present, or both unparseable | nothing |
| Off | `isEnabled == false` | `Extra usage · off` + **Turn on at claude.ai ↗** |
| On, capped | `isEnabled`, `limit != nil` | `€75.09 of €110.00 this month` · `68%` · progress bar |
| On, uncapped | `isEnabled`, `limit == nil` | `€75.09 this month · no limit set` |
| Blocked | `capReached` or `disabledReason != nil` | red, plain-language reason + **Manage ↗** |

The bar follows the existing usage-row colour ramp: normal, amber past 80%, red past 95%.

`Manage ↗` is always present when the section shows. `Buy credits ↗` appears **only** when
`canPurchase` is true — on the author's account it is false, so only `Manage ↗` shows.

`disabledReason` maps to human copy for the values observed in the CLI (`out_of_credits`,
`org_level_disabled_until`, `org_spend_cap_reached`, `overage_not_provisioned`) with a safe
generic fallback for anything unrecognised, since the vocabulary is undocumented and will grow.

`spend.disclaimer` is server-supplied copy containing a markdown link to the support article.
It renders as the section's tooltip — server-supplied so it stays current, tooltip so it does
not clutter a dropdown that is already dense.

### Widget

One compact row — `€75.09 / €110.00 · 68%` — carried in the **existing** `SessionSnapshot`,
which already ships `usageGauges` sourced from the same `UsageStore` reading via
`SessionMonitor.usageProvider`. No third snapshot file: the API-spend feature needed one only
because its producer runs on a different cadence and would race; extra usage shares a producer
with the gauges it sits beside.

`SessionSnapshot` gains `extraUsage: ExtraUsage?`, decoded with `decodeIfPresent` so an older
widget reading a newer snapshot (and the reverse) keeps working.

### Notifications

Three, through the existing `NotificationManager`, **on by default**, with one Settings
checkbox to silence them:

1. **Spending started** — `used` crossed from zero to non-zero this period.
2. **80% of the cap** — only when a cap exists.
3. **Cap reached** — `capReached`, or utilization ≥ 100.

Each fires at most once per billing period.

**The hard part: there is no reset date.** The API returns `daily: null`, `weekly: null` and no
`resets_at` for spend, so the *only* signal that a new billing month has begun is **`used`
dropping**. Notification state resets on that drop. This is structurally the same problem as
`UsageStats.didRefill`, and it gets the same treatment — a pure, fully-tested decision function
in core rather than logic scattered through a store:

```swift
public enum ExtraUsageAlerts {
    public static func decide(
        previous: ExtraUsage?, current: ExtraUsage, notified: Set<Alert>
    ) -> (fire: [Alert], notified: Set<Alert>)
}
```

`notified` persists in `Settings`. Edge cases the tests must pin: a drop resets the set; a rise
past a threshold already in the set fires nothing; no alerts at all when `isEnabled` is false;
the 80% alert never fires without a cap; a `nil` current reading changes nothing.

## Why links, not writes

The write endpoints exist — `PUT /api/oauth/organizations/:orgUUID/overage_spend_limit`,
`POST …/contracts/prepaid/credits`, `PUT …/contracts/auto_reload_settings` — all undocumented,
all authenticated as `teleport-org`, all moving real money, with Stripe 3DS fallbacks the CLI
itself bails to the browser to handle.

Three facts settled this:

1. **Claude Code has no off switch either.** Every write in the binary sends `is_enabled: true`.
   Its inline dialog offers continue / buy / adjust limit / auto-reload / **manage**, and
   "manage" opens `https://claude.ai/settings/usage`. Turning extra usage *off* is a browser
   action even in Anthropic's own client.
2. **The server says this account cannot toggle or purchase** (`can_toggle: false`,
   `can_purchase_credits: false`), so an in-app switch would ship greyed out.
3. A menu-bar popover charging a card against an undocumented endpoint is the wrong place for
   that risk, and every such endpoint is one server change away from breaking.

A "stop spending now" brake (set the monthly limit to the amount already spent) was considered
and rejected: it needs an unverified auth path, and because the limit is monthly and persists,
a panic click today silently becomes next month's budget.

## Links

One constant per destination, in a single `ClaudeLinks` enum rather than scattered string
literals:

- Manage / enable / raise the cap: `https://claude.ai/settings/usage`
- Learn more: whatever `spend.disclaimer` carries (server-supplied)

The CLI appends `?from=cc_cli_limit_message` for its own attribution; ClaudeMeter sends the
plain URL rather than impersonating it.

## Files

**Core** (tested, Swift 6 strict):
- `Models/Money.swift` — new
- `Models/ExtraUsage.swift` — new
- `Services/ExtraUsageAlerts.swift` — new
- `Services/UsageResponseDecoder.swift` — parse `spend` / `extra_usage`
- `Models/UsageSnapshot.swift` — `extraUsage` field
- `Models/SessionSnapshot.swift` — `extraUsage` field
- `Formatting.swift` — currency-agnostic money formatting (half-up, like `usd`)

**App:**
- `Views/ExtraUsageSection.swift` — new
- `Views/MenuContentView.swift` — mount the section
- `App/UsageStore.swift` — alert decisions on each reading
- `App/SessionMonitor.swift` — carry the figure into the widget payload
- `Support/Settings.swift` — notification toggle + persisted alert state
- `Views/SettingsView.swift` — the checkbox
- `Support/ClaudeLinks.swift` — new

**Widget:** one row in the existing view.

**Docs:** `docs/anthropic-endpoints.md` — the `extra_usage` and `spend` shapes, the precedence
rule, the minor-units trap, and the absence of a reset date.

## Testing

Core line coverage stays ≥ 80% (`scripts/coverage-gate.sh`). Fixtures:

- `spend` only; `extra_usage` only; both present and agreeing; both present and disagreeing
  (spend wins)
- unlimited (`limit: null`); zero-exponent currency (JPY); non-EUR/USD currency
- missing `currency`, missing `exponent`, non-numeric `amount_minor` → `nil`, not zero
- `capReached`, each known `disabledReason`, an unknown `disabledReason`
- money formatting: EUR symbol placement, half-up rounding, sub-unit amounts
- `ExtraUsageAlerts`: each threshold once, reset on drop, disabled account, no-cap account,
  nil reading

## Open questions

None blocking. If the plain figure proves insufficient in daily use, spend history and a
burn-rate projection are the natural next increment, and `UsageHistory` already provides the
persistence shape for it.
