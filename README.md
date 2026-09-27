# Subar

A lightweight macOS menu bar app that shows your AI subscription limits, local token usage over time, and what that usage would have cost at API prices.

Status: **v0.1, Codex only.** Claude comes next. See [SPEC.md](SPEC.md) for the full v1 scope, [CONTEXT.md](CONTEXT.md) for vocabulary, and [ADR 0001](docs/adr/0001-read-only-credentials.md) for the read-only credential policy.

## What it shows

- **Menu bar:** a ring plus the percentage used of your Pinned Limit (by default the 5-hour window, or weekly if that is the only one). Click any Limit Window in the popover to pin it.
- **Codex card:** plan, Limit Windows with reset countdowns, credits, Banked Resets.
- **Usage:** Today / 7d / 30d tokens and Theoretical Cost (API-equivalent, from [models.dev](https://models.dev)), a daily chart, and top models and projects.
- **Limit Alerts:** notifications at 90% and 95% of the 5-hour and weekly windows, and when a window resets after passing 90%.

## How it gets data (read-only)

| What | Source |
|---|---|
| Codex limits | `GET chatgpt.com/backend-api/wham/usage` and `/wham/rate-limit-reset-credits`, authenticated with the tokens the Codex CLI stores in `~/.codex/auth.json` |
| Fallback | a short-lived `codex -s read-only -a never app-server`, JSON-RPC `account/rateLimits/read` |
| Token history | `~/.codex/sessions/**/*.jsonl` and `~/.codex/archived_sessions` |
| Prices | `models.dev/api.json`, at most once per day |

Subar never refreshes or writes the CLI's tokens. If the login expires, the card turns **Stale** and asks you to run `codex` once.

### Codex log accounting

Each `token_count` event carries that response's usage (`last_token_usage`). Two kinds of events are skipped:

- **Repeats:** the same cumulative total logged twice.
- **Fork replay:** a forked session starts by copying its parent's history, including the parent's token events. Those copied events carry the fork's own timestamp, so events stamped at or before the fork's `session_meta` time are not counted again.

On the maintainer's 100k-file, 16 GB history this matches an independent recount exactly.

## Performance

Measured on an Apple Silicon Mac with that 16 GB Codex history:

| | |
|---|---|
| Idle CPU | 0.0% (one 5-minute poll timer, no animations) |
| Idle footprint | ~20 MB |
| Incremental ingest | FSEvents tells Subar which files changed; only appended bytes are read |
| First launch import | ~80 s in a background child process, which exits when done |

## Build

```sh
swift build                       # debug
swift test                        # unit tests
./Scripts/build-app.sh            # universal build/Subar.app, ad-hoc signed
open build/Subar.app
```

To sign for distribution, set `SIGN_IDENTITY="Developer ID Application: …"`. Notarization, Sparkle and the Homebrew cask are not set up yet.

Developer tools:

```sh
swift run subar-cli limits        # fetch Codex limits
swift run subar-cli ingest [db]   # ingest Codex logs
swift run subar-cli usage [db]    # print usage summaries
.build/debug/Subar --snapshot out.png   # render the popover to PNG (light + dark)
```

## License

MIT
