# Read-only access to provider credentials

Tinybar uses the logins that the official clients already keep: Claude Code's and Codex's OAuth tokens, Cursor.app's stored token, and, when enabled, browser session cookies (ADR 0005). It never refreshes a token, never writes to a client's credential store, and never calls an endpoint that changes account state, such as sending a prompt or redeeming a Banked Reset. When a login has expired the Provider turns Stale, with a hint to run the CLI or open the app once, and that client renews its own login.

We accept stale data so that Tinybar's traffic looks like the client's own read-only traffic, which keeps the risk of an account being flagged low. Rotating a refresh token behind a CLI's back can also sign the user out of that CLI. CodexBar refreshes tokens for some providers, for example by rewriting the Gemini CLI's credential file; we deliberately don't copy that.

Where a Provider exposes no readable token, Tinybar runs the client itself for a single read-only call and lets it handle its own login: `agy -p /usage` for Gemini, and `codex app-server` as the Codex fallback. Tinybar never sees a Google token.

## Consequences

- If a CLI sits unused until its login expires, that Provider's limits go stale. That is intended, not a bug to fix with a refresh flow.
- If staleness becomes a real problem, revisit it with a new ADR rather than quietly adding refresh logic.
