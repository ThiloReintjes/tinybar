# Read-only access to provider credentials

Tinybar reads the OAuth tokens that the official CLIs (Claude Code, Codex) already store, and optionally browser cookies, but never refreshes a token, never writes to a CLI's credential files, and never sends prompts. When a token has expired, the Provider is shown as Stale with a hint to run the CLI once, instead of Tinybar refreshing it. We accept stale data in exchange for keeping Tinybar indistinguishable from the CLI's own read-only traffic, which minimises the risk of the user's subscription being flagged or banned. CodexBar refreshes tokens itself for some providers (e.g. rewriting the Gemini CLI's credential file), which we deliberately do not copy.

## Consequences

- An idle CLI means stale limits for that Provider. That is by design, not a bug to "fix" with a refresh flow.
- If staleness becomes a real problem, revisit with a new ADR rather than quietly adding refresh logic.
