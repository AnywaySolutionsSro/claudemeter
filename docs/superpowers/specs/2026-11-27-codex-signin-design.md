# ChatGPT sign-in for live Codex limits — design

Date: 2026-11-27 · Status: approved by Jakub (chat, 2026-11-27) · Third PR, stacked on `feat/codex`.

## Why
Codex limits read from transcripts are only as fresh as the last Codex turn ("as of 2h ago").
Jakub wants Codex authenticated "the same way there is authentication to Claude", so the
numbers are live.

## Decided
- ClaudeMeter's **own** OAuth (PKCE, S256) against OpenAI, mirroring the Claude login:
  authorize `https://auth.openai.com/oauth/authorize`, token `https://auth.openai.com/oauth/token`,
  public Codex CLI client id `app_EMoamEEZ73f0CkXaXp7hrann` (from the Codex binary — same
  precedent as reusing Claude Code's public client id), redirect
  `http://localhost:1455/auth/callback` (the registered one; listener binds 127.0.0.1 only,
  accepts only the matching `state`, 10-min timeout; if 1455 is busy — e.g. `codex login` running —
  show a clear error, no other port).
  Authorize params: `response_type=code`, `client_id`, `redirect_uri`,
  `scope=openid profile email offline_access`, `code_challenge`, `code_challenge_method=S256`,
  `state`, `id_token_add_organizations=true`, `codex_cli_simplified_flow=true`.
- Tokens (access, refresh, id token, expiry, ChatGPT account id from the id token's
  `https://api.openai.com/auth` → `chatgpt_account_id` claim) in **ClaudeMeter's own Keychain
  item** `com.jakubzak.claudemeter.chatgpt`. Never read/write `~/.codex/auth.json`.
  Refresh with `grant_type=refresh_token`; refresh failure (invalid_grant) ⇒ signed-out state with
  "Sign in again".
- Live limits: `GET https://chatgpt.com/backend-api/wham/usage`, `Authorization: Bearer`,
  `chatgpt-account-id: <id>`; poll ~60 s, ≥30 s throttle, honour `Retry-After`/back off on 429,
  refresh-and-retry once on 401. Undocumented ⇒ **lenient** key-by-key decoding into the existing
  `CodexLimitReading`; unknown shape ⇒ no reading (never a zero). Diagnostic
  `ClaudeMeter --codex-usage-dump` prints the response **structure** (keys/types, no values).
- Source choice: the newest reading (by `observedAt`) of live vs transcript wins; signed out ⇒
  transcripts only, exactly as today. Everything downstream (gauges, pill, graph, alerts,
  auto-resume gate) consumes the same `CodexLimitReading`.
- UI: Settings → "Codex" group: "Sign in to ChatGPT" / signed-in email + "Sign out"; dropdown
  Codex section shows a small "Sign in for live limits" link when signed out and Codex present;
  "as of" disappears while live readings are fresh.
- Logs: category `chatgpt` at `.notice` (failures, sign-in/out), never tokens.

## Anti-goals
Touching Codex's auth.json; logging tokens; a zero/blank reading on a decode failure; breaking
the signed-out path.

## Left to the builder
File layout, names, poll cadence details within the bounds above, Settings copy.
