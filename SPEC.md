# Subar — v1 Specification

A lightweight, native macOS menu bar app showing AI subscription limits, local token usage over time, and the Theoretical Cost of that usage. It is a from-scratch alternative to [CodexBar](https://github.com/steipete/CodexBar) (about 309k LOC, 87 providers), built around performance and a small scope.

Vocabulary: see [CONTEXT.md](./CONTEXT.md). Key decision: [ADR 0001](./docs/adr/0001-read-only-credentials.md).

## 1. Goals and non-goals

**Goals**
- A one-command install that runs with zero configuration.
- Near-zero resource use (see §2).
- Accurate Limit Windows, Resets and Banked Resets for Claude and Codex.
- Daily token history and Theoretical Cost from local CLI logs.
- Publishable: MIT license, notarized, auto-updating.

**Non-goals (v1)**
- Providers other than Claude and Codex. Gemini, Cursor, Grok and Kimi come later, one at a time.
- Multiple accounts per Provider.
- Refreshing tokens or writing to CLI credential files (ADR 0001).
- Token usage from web/desktop chat apps (no local logs).
- Historical pricing.
- A separate window. Everything lives in the popover.
- Widgets, CLI companion, config files.

## 2. Performance budget (acceptance criteria)

| Metric | Target |
|---|---|
| CPU when idle (popover closed, between polls) | 0% |
| Resident memory (RSS) | < 50 MB steady state |
| Timers | None faster than the 5-minute poll; no animation loops |
| Log parsing | Incremental only. Each file is read from a stored byte offset; a full rescan happens only on first launch or for a truncated/replaced file |

No WebViews, no embedded JS engines, and no long-lived child processes.

Known CodexBar pitfalls to avoid: full-corpus rescans (#2538), competing caches (#3769), Keychain prompt/rejection growth (#3300), runaway animation (#842), unexplained memory growth (#3323).

## 3. Platform and stack

- Swift, macOS 14+, universal binary (Apple Silicon is the priority for testing).
- AppKit `NSStatusItem` plus a SwiftUI popover (`NSPopover`). Charts use Swift Charts.
- Persistence uses the system SQLite (`libsqlite3`).
- Dependencies: Sparkle (updates). Anything else must justify itself against §2.
- Launch at login via `SMAppService`, on by default.

## 4. Providers (v1)

For each Provider, the source order is inspired by CodexBar and everything is strictly read-only (ADR 0001).

### Claude
1. **CLI OAuth**: read the token from `~/.claude/.credentials.json`, else Keychain item `Claude Code-credentials`.
   → `GET https://api.anthropic.com/api/oauth/usage` (plus `/api/oauth/profile` for the plan name), with the same headers the official CLI sends.
2. **Browser cookie fallback** (opt-in in Settings): `sessionKey` from Safari/Chromium/Firefox → `claude.ai/api/organizations/{id}/usage`.

Displayed: 5h session window, weekly window, model-specific weekly windows (e.g. Opus/Sonnet), extra usage spend if present, and a Reset time for each.
Honor `Retry-After`; on HTTP 429 with no header, back off 5 minutes.

### Codex
1. **CLI OAuth**: read `~/.codex/auth.json` (respect `CODEX_HOME`).
   → `GET https://chatgpt.com/backend-api/wham/usage` for the 5h and weekly windows, Resets and credits.
   → `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` for Banked Resets (status and expiry). Display only; never redeem.
2. **CLI app-server fallback**: `codex -s read-only -a never app-server`, JSON-RPC `account/rateLimits/read`. The process is short-lived and terminated after the call.
3. **Browser cookie fallback** (opt-in).

Displayed: 5h window, weekly window, model-specific windows if present, credits, Banked Resets.

### Detection and staleness
- On launch, a Provider is enabled automatically if its CLI credentials exist. It can be toggled in Settings.
- If a fetch fails (expired token, network, 401), the Provider becomes **Stale**. The card keeps its last values and shows "Stale since HH:MM — run `claude` once to refresh" (or `codex`).

Implementation note: endpoint shapes are undocumented. Verify request headers and response fields against CodexBar's sources (`Sources/CodexBarCore/Providers/{Claude,Codex}/`, `docs/codex.md`) before implementing.

## 5. Refresh policy

- A fixed 5-minute poll per enabled Provider.
- An extra refresh when the popover opens, throttled to at most once per 60 s per Provider.
- A manual refresh button (same throttle).
- Paused while the Mac sleeps or the screen is locked. On wake or unlock, refresh once.
- Per-Provider backoff when the server asks for it (`Retry-After`, 429).
- Log ingestion runs on the same poll, and when the popover opens (cheap because it is incremental).

## 6. Menu bar

- A tiny ring glyph showing how much of the Pinned Limit is **left**: full at 100%, empty at 0%, with the percentage next to it (`◕ 77%`). Settings has "hide percentage".
- **Pinned Limit**: chosen by clicking any Limit Window in the popover. The default is the 5h window of the first enabled Provider (Claude before Codex), or its weekly window if no 5h window exists.
- If the Pinned Limit's Provider is Stale, the glyph is dimmed.

## 7. Popover (about 340 pt wide; height grows, scrolls when needed)

1. **Provider cards**, one per enabled Provider:
   - Name plus plan.
   - For each Limit Window: a bar that drains as usage grows, % left, and a reset countdown ("resets in 2h 14m"). Click to pin; the pinned one is marked.
   - Codex: credits and Banked Resets (count, expiry).
   - Stale line when applicable.
2. **Usage section**, with tabs for Today, 7d and 30d:
   - Total tokens and Theoretical Cost.
   - A daily bar chart stacked by Provider (7d/30d).
   - Top models (tokens, cost).
   - Top Projects as side info, where the Provider's logs contain a working directory.
   - A progress hint during the first-launch import.
   - Today is marked provisional (see Provisional Day).
3. **Footer**: last updated time, refresh, settings (gear), quit.

**Settings** (small pane): Provider toggles, launch at login, notifications, the browser cookie fallback per Provider (off by default; enabling it may trigger a macOS Keychain prompt for the browser's storage key), and hide percentage.

## 8. Limit Alerts

- Scope: the 5h and weekly Limit Windows of every enabled Provider (not model-specific windows).
- Notify once when a window crosses **90%**, and once when it crosses **95%**.
- Notify on **Reset** only if that window crossed 90% before resetting.
- De-duplicate per (Provider, window, reset time), so a notification never repeats within one window cycle, including across app restarts.
- Ask for notification permission once, on first launch.

## 9. Token history

### Sources
- **Claude**: `~/.claude/projects/**/*.jsonl`. Assistant messages with `usage` (input, output, cache creation, cache read), `model`, `timestamp`, `cwd`. De-duplicate by message id plus request id; the same response can appear several times.
- **Codex**: `~/.codex/sessions/**` (and archived sessions). Token counts are cumulative per session, so store deltas and handle forked sessions without double counting.

Parsing rules must be verified against CodexBar's `Sources/CodexBarCore/Vendored/CostUsage/` before implementing.

### Ingestion
- **First launch**: import all available logs once, in the background at low priority (`.utility`), with progress shown in the popover.
- **Afterwards**: incremental. Store per file (path, inode, size, mtime, byte offset). Only read appended bytes. Re-read a file from zero if it was truncated or replaced.
- Stored daily totals survive the CLIs deleting old logs (Claude Code deletes after 30 days by default).

### Store (SQLite, `~/Library/Application Support/Subar/usage.sqlite`)
- `daily_usage(day, provider, model, project, input, output, cache_write, cache_read)`, primary key (day, provider, model, project).
- `file_cursor(path, inode, size, mtime, offset)`.
- Dedupe keys for Claude, pruned after a reasonable horizon.
- The schema allows a future `account` column (multi-account later).

### Day boundary
- Local calendar day, midnight to midnight, based on each record's timestamp in the current time zone.
- **Provisional Day**: today (and yesterday, until 01:00) is shown as provisional because logs can be written late. It is re-aggregated on each ingest; after that it is final.

### Project
- Walk up from the record's working directory to the nearest folder containing `.git`.
- A Worktree (`.git` file pointing into another repo) is attributed to its main repository.
- Projects are identified by repo root path and displayed by folder name.
- If the path no longer exists, use its last path component.
- If no repository is found, file it under "No project".
- Cache path→project lookups in memory.

## 10. Theoretical Cost

- Prices (input, output, cache write, cache read per model) come from **models.dev**, fetched at most once per 24 h with a single unauthenticated GET. The last successful response is cached on disk.
- No bundled price table. If no prices have ever been fetched, or a model is not listed, show "—". Never guess from a similar model.
- Always use **current** prices, computed from stored token counts at display time.
- Theoretical Cost is not what the user paid; the UI labels it "API-equivalent".

## 11. Distribution

- GitHub repo `subar`, MIT license.
- Signed with Developer ID and notarized (the owner provides the Apple Developer account).
- Released on GitHub Releases, plus a Homebrew cask: `brew install --cask subar`.
- Sparkle for in-app auto-updates (EdDSA-signed appcast).
- First run needs no configuration: auto-detect Providers, launch at login, request notification permission.

## 12. Later (explicitly deferred)

Gemini, Cursor, Grok, Kimi providers; token history for other CLIs; multiple accounts; token refresh (would need a new ADR); historical pricing; a separate Usage window.
