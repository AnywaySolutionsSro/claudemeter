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
  "extra_usage":      { "is_enabled": false, "monthly_limit": 11000, "...": "..." },
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
- HTTP **429** is returned when polling too often; honor `Retry-After`.

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
