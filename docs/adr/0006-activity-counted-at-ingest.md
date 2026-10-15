# Count Activity at ingest, with fixed definitions

The Stats window shows Activity (Prompts, Tool Calls, lines written, Compactions, Agent Time, Output Speed) from the same Claude Code and Codex logs as token history. It is counted while logs are ingested and stored as daily counters, one row per (day, Provider, model, key) holding a sum or a maximum. Keys are strings such as `tool.Bash` or `hour.14`, so a new counter needs no schema change. Nothing else is kept: no commands, file names, prompts or diffs.

Claude Code repeats lines when a session is resumed or forked, and streams one response over several lines that two reads can split. Each Claude message therefore keeps what was counted for it (its tool call ids and timestamps) next to its token counts, and a later read replaces that contribution instead of adding to it. One-off events (Prompts, edit results, Compactions) are recorded by id, for the same 90 days as message ids. Codex logs are read in order per file, with the fork rule token counting already uses.

The alternative was to store raw events and compute stats when the window opens. That keeps every definition changeable, but it stores far more, puts per-command records on disk, and still loses everything older than the logs Claude Code keeps (30 days).

## Consequences

- Definitions are hard to change. Claude Code deletes transcripts after 30 days, so a changed rule (the 30-minute pause in Agent Time, the 200-token floor for Output Speed) only applies to logs still on disk; older days keep the old rule.
- Users upgrading from a version without Activity get a one-time backfill from the logs still on disk. Older days show tokens but no Activity, and the Stats window says from when Activity is counted.
- Output Speed includes the wait for the first token, so it is lower than a provider's generation speed and depends on context size. It is comparable across a user's own models and days, which is what the window uses it for.
- Codex reports agent actions as `item_completed` events in current versions and as named tool calls in older ones. Both are read; the older format could not be checked against real logs.
