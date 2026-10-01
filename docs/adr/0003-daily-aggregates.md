# Store daily totals, not individual Usage Records

The history database keeps one row per (day, Provider, model, Project) with summed token counts, plus a byte offset per log file. It does not keep individual Usage Records, prompts or responses. For Claude it additionally keeps each message ID with the tokens counted for it, because Claude Code writes the same response several times and later copies can be more complete. That table holds IDs and counts only. IDs older than 90 days are pruned: copies of a message turned up at most 29 days later in real logs, and Claude Code deletes transcripts after 30 days.

Daily totals cover everything the popover shows (Today, 7 and 30 days, models, Projects) and stay small: a few thousand rows from 24 GB of logs. They also keep nothing more sensitive than token counts and folder paths on disk (SECURITY.md).

## Consequences

- History outlives the logs. Claude Code deletes transcripts after 30 days, but their totals remain.
- That makes the aggregation hard to reverse. A finer view, such as hourly usage or per session, only works for logs still on disk. Older days stay at daily resolution forever.
- Days are local calendar days, fixed when a record is ingested. Changing time zone doesn't re-bucket past days.
