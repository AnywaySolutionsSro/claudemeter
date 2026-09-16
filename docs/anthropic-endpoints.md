# Anthropic endpoints reference (reverse-engineered)

> **Undocumented.** These were recovered by `strings`-grepping the Claude Code CLI binary
> (`~/.local/share/claude/versions/2.1.195`), not from public documentation. They can change
> without notice. Parse leniently and degrade gracefully. All values below (client id, beta
> header) are public values embedded in the CLI, not secrets.

## Usage

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <access_token>
anthropic-beta: oauth-2025-04-20
Accept: application/json
```

### Response (observed)

```json
{
  "five_hour":        { "utilization": 55.0, "resets_at": "2026-06-27T16:19:59.398499+00:00" },
  "seven_day":        { "utilization": 11.0, "resets_at": "2026-07-04T04:59:59.398532+00:00" },
  "seven_day_opus":   null,
  "seven_day_sonnet": { "utilization": 0.0,  "resets_at": "2026-07-04T04:59:59.398543+00:00" },
  "extra_usage":      { "is_enabled": true, "monthly_limit": 11000, "used_credits": 7509.0,
                        "utilization": 68.26, "currency": "EUR", "decimal_places": 2,
                        "disabled_reason": null, "spend_limit_reached": false },
  "limits":           [ { "kind": "session", "percent": 55, "resets_at": "...", "is_active": true }, ... ],
  "spend":            { "...": "..." }
}
```

- `utilization` — percent **used** (0–100), a JSON number. "Remaining" = `100 - utilization`.
- `resets_at` — **ISO-8601 string** with microsecond precision and timezone offset. NOT epoch
  seconds (the CLI's own doc comment is wrong about this). `ISODate` strips fractional seconds
  before parsing because `ISO8601DateFormatter` only handles milliseconds.
- Buckets may be `null` (plan doesn't have them) or absent. ClaudeMeter consumes `five_hour`,
  `seven_day`, `seven_day_opus`, `seven_day_sonnet`, and the `limits` array.
- Other bucket keys exist (`seven_day_oauth_apps`, `seven_day_cowork`, codenamed ones such as
  `nimbus_quill`, `cinder_cove`); ignored.
- **`limits[]`** (observed 2026-08-28) is the structured view of the same windows and the only
  place per-model weekly limits appear for current plans (`seven_day_opus/sonnet` are `null`):

  ```json
  { "kind": "session",       "group": "session", "percent": 17, "severity": "normal",
    "resets_at": "…", "scope": null, "is_active": false },
  { "kind": "weekly_all",    "group": "weekly",  "percent": 44, "…": "…" },
  { "kind": "weekly_scoped", "group": "weekly",  "percent": 68, "severity": "normal",
    "resets_at": "…", "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
    "is_active": true }
  ```

  `UsageResponseDecoder` turns every `weekly_scoped` entry with a `scope.model.display_name`
  into a `ModelWeeklyLimit` (label = the server-supplied name, so new tiers need no code
  change; `percent` = utilization; `is_active` = the binding window). The Claude Code binary
  describes it as "Server-supplied label for the model bucket (e.g. 'Fable')". If `limits[]`
  and a legacy `seven_day_<model>` bucket name the same model, the scoped entry wins.
- **`extra_usage` / `spend`** are two overlapping views of the same paid-overage
  allowance. `spend` is the newer, structured one and **wins** when both are present
  (the same precedence `limits[]` has over `seven_day_<model>`); `extra_usage` is the
  fallback. `ExtraUsage` in the core is decoded from whichever reads cleanly.

  ```json
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

  - Money is **minor units plus the currency's own exponent** — `{7509, "EUR", 2}` is
    €75.09. Never assume two decimal places (JPY uses zero) and never assume USD. A
    block whose amount, currency or exponent doesn't parse yields **no reading**, never
    a zero.
  - **There is no reset date for the monthly spend window.** `daily` and `weekly` are
    null and `spend` carries no `resets_at`, so the only evidence a new billing period
    began is the spent amount **dropping** (`ExtraUsageAlerts` depends on this).
  - `can_toggle` and `user_disabled` appear in the response but **not** in the Claude
    Code binary (2.1.266) — they are newer than the client and what gates them is
    unverified. Only `can_purchase_credits` is consumed by the CLI.
- HTTP **429** is returned when polling too often; honor `Retry-After`.

## Extra usage: the write endpoints (NOT used by ClaudeMeter)

Recorded so nobody has to re-derive them. All undocumented, all authenticated as
`teleport-org`, all moving real money. ClaudeMeter is read-only and opens
`https://claude.ai/settings/usage` instead.

```
PUT  /api/oauth/organizations/:orgUUID/overage_spend_limit
     { "is_enabled": true }                                     # turn on
     { "is_enabled": true, "monthly_credit_limit": 11000, "currency": "EUR" }
POST /api/oauth/organizations/:orgUUID/setup_overage_billing    { "org_monthly_spend_limit": … }
PUT  /api/oauth/organizations/:orgUUID/contracts/auto_reload_settings
POST /api/oauth/organizations/:orgUUID/contracts/prepaid/credits  # buy, Stripe + 3DS
```

**Claude Code has no off switch.** Every write in its binary sends `is_enabled: true`;
its inline dialog offers continue / buy / adjust limit / auto-reload / **manage**, and
"manage" opens the browser. Turning extra usage *off* is a web action even there.

## OAuth (authorization code + PKCE)

Public client used by Claude Code:

| Field          | Value                                                          |
| -------------- | -------------------------------------------------------------- |
| `client_id`    | `9d1c250a-e61b-44d9-88ed-5944d1962f5e`                         |
| Authorize URL  | `https://claude.ai/oauth/authorize`                            |
| Token URL      | `https://platform.claude.com/v1/oauth/token`                   |
| Scopes         | `org:create_api_key user:profile user:inference`              |
| Redirect (auto)| `http://localhost:<port>/callback`  (loopback — what we use)   |
| Redirect (manual)| `https://platform.claude.com/oauth/code/callback`           |
| PKCE           | `code_challenge_method=S256`                                   |
| beta header    | `oauth-2025-04-20`                                             |

### Authorize request

```
GET https://claude.ai/oauth/authorize
  ?code=true
  &client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e
  &response_type=code
  &redirect_uri=http://localhost:<port>/callback
  &scope=org:create_api_key user:profile user:inference
  &code_challenge=<S256(verifier)>
  &code_challenge_method=S256
  &state=<random>
```

The browser redirects to the loopback URL with `?code=...&state=...`, captured by
`LoopbackCallbackServer`. In the manual flow the hosted callback page shows `CODE#STATE` to paste.

### Token exchange / refresh

```
POST https://platform.claude.com/v1/oauth/token
Content-Type: application/json
anthropic-beta: oauth-2025-04-20

# authorization_code:
{ "grant_type": "authorization_code", "code", "state", "client_id",
  "redirect_uri", "code_verifier" }

# refresh:
{ "grant_type": "refresh_token", "refresh_token", "client_id" }
```

Response: `{ "access_token", "refresh_token", "expires_in" }`.

## Claude Code's Keychain item (NOT used by ClaudeMeter)

For reference only — ClaudeMeter has its **own** item and never touches this one:

```
service = "Claude Code-credentials"
{ "claudeAiOauth": { "accessToken", "refreshToken", "expiresAt" (epoch ms),
                     "subscriptionType", "scopes" } }
```

## Re-deriving after a Claude Code update

```bash
BIN=~/.local/share/claude/versions/<version>
strings -n 6 "$BIN" | grep -iE 'oauth/usage|five_hour|seven_day|resets_at|utilization'
strings -n 6 "$BIN" | grep -iE 'oauth/authorize|/v1/oauth/token|redirect_uri|code_challenge|scope'
```
