---
name: claude-usage-monitoring
description: Use when building a tool that reads a Claude (Anthropic) subscription's usage — percent used and reset times for the 5-hour/weekly rate-limit windows — programmatically via the same OAuth endpoint Claude Code's /usage uses.
---

# Reading Claude subscription usage programmatically

The real, server-side usage numbers (what `claude` shows in `/usage`) come from an
**undocumented** OAuth-authenticated endpoint. There is no published API; everything here was
recovered by `strings`-grepping the Claude Code CLI binary. Treat it as fragile.

## Endpoint

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <access_token>
anthropic-beta: oauth-2025-04-20
```

Response: buckets `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` (any may be
`null`), each `{ "utilization": <0-100 number>, "resets_at": <ISO-8601 string> }`. There is also
a `limits` array and `spend`/`extra_usage` objects.

- **`utilization` is percent USED.** Remaining = `100 - utilization`.
- **`resets_at` is an ISO-8601 string with microseconds** (`2026-06-27T16:19:59.398499+00:00`),
  NOT epoch seconds. `ISO8601DateFormatter` only handles milliseconds — strip the fractional
  part before parsing.
- **HTTP 429** when polling too often — honor `Retry-After`, cache the last reading, poll on the
  order of minutes, not seconds.
- Parse **leniently** (key-by-key, ignore unknown keys, missing buckets → nil). The shape will
  change.

## Getting a token

Two options:

1. **Your own OAuth login (recommended for standalone tools).** Authorization-code + PKCE:
   - `client_id` `9d1c250a-e61b-44d9-88ed-5944d1962f5e`
   - authorize `https://claude.ai/oauth/authorize`, token `https://platform.claude.com/v1/oauth/token`
   - scopes `org:create_api_key user:profile user:inference`, `code_challenge_method=S256`
   - redirect: loopback `http://localhost:<port>/callback` (allows fully automatic capture — run
     a throwaway local HTTP server) or hosted `https://platform.claude.com/oauth/code/callback`
     (shows `CODE#STATE` to paste).
   - Store the resulting token in your **own** Keychain item / secret store.

2. **Reuse Claude Code's token** from the macOS Keychain item `Claude Code-credentials`
   (JSON `claudeAiOauth.{accessToken, refreshToken, expiresAt (epoch ms)}`). Simpler, but causes
   cross-app Keychain prompts and you risk rotating its refresh token. Prefer option 1.

Refresh: `POST .../v1/oauth/token` with `{ grant_type: "refresh_token", refresh_token, client_id }`.

## Re-deriving after a Claude Code update

```bash
BIN=~/.local/share/claude/versions/<version>     # the CLI is a single large binary
strings -n 6 "$BIN" | grep -iE 'oauth/usage|five_hour|resets_at|utilization'
strings -n 6 "$BIN" | grep -iE 'oauth/authorize|/v1/oauth/token|redirect_uri|code_challenge|scope'
```

These are public values embedded in the CLI, not secrets. Never bundle real tokens.
