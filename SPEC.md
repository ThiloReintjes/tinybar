# Tinybar — v1 Specification

A lightweight, native macOS menu bar app showing AI subscription limits, local token usage over time, and the Theoretical Cost of that usage. It is a from-scratch alternative to [CodexBar](https://github.com/steipete/CodexBar) (about 309k LOC, 87 providers), built around performance and a small scope.

Vocabulary: see [CONTEXT.md](./CONTEXT.md). Decisions: [docs/adr/](./docs/adr), above all [ADR 0001](./docs/adr/0001-read-only-credentials.md) (read-only credentials).

## 1. Goals and non-goals

**Goals**
- A one-command install that runs with zero configuration.
- Near-zero resource use (see §2).
- Accurate Limit Windows, Resets and Banked Resets for Claude, Codex, Gemini and Cursor.
- Daily token history and Theoretical Cost from local CLI logs.
- Publishable: MIT license, notarized, auto-updating.

**Non-goals (v1)**
- Providers other than Claude, Codex, Gemini and Cursor. Grok and Kimi come later, one at a time.
- Token history for Gemini and Cursor (neither keeps usable local logs; limits only).
- Multiple accounts per Provider.
- Refreshing tokens or writing to CLI credential files (ADR 0001).
- Token usage from web/desktop chat apps (no local logs).
- Historical pricing.
- More windows. Limits and usage live in the popover; the only window is Stats (§13).
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
- Plain SwiftPM, no dependencies except Sparkle for updates (ADR 0002).
- Launch at login via `SMAppService`, on by default.

## 4. Providers (v1)

For each Provider, the source order is inspired by CodexBar and everything is strictly read-only (ADR 0001).

### Claude
1. **CLI OAuth**: read the token from `~/.claude/.credentials.json`, else Keychain item `Claude Code-credentials`.
   → `GET https://api.anthropic.com/api/oauth/usage` (plus `/api/oauth/profile` for the plan name), with the same headers the official CLI sends.
2. **Browser cookie fallback** (opt-in in Settings, ADR 0005): `sessionKey` from Chromium browsers or Firefox → `claude.ai/api/organizations/{id}/usage`. Safari is out (needs Full Disk Access).

Displayed: 5h session window, weekly window, model-specific weekly windows (e.g. Opus/Sonnet), extra usage spend if present, and a Reset time for each.
Honor `Retry-After`; on HTTP 429 with no header, back off 5 minutes.

### Codex
1. **CLI OAuth**: read `~/.codex/auth.json` (respect `CODEX_HOME`).
   → `GET https://chatgpt.com/backend-api/wham/usage` for the 5h and weekly windows, Resets and credits.
   → `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` for Banked Resets (status and expiry). Display only; never redeem.
2. **CLI app-server fallback**: `codex -s read-only -a never app-server`, JSON-RPC `account/rateLimits/read`. The process is short-lived and terminated after the call.
3. **Browser cookie fallback** (opt-in): chatgpt.com session cookie → `/api/auth/session` access token → the `wham` endpoints. A session the browser has not refreshed (`error: RefreshAccessTokenError`) counts as expired.

Displayed: 5h window, weekly window, model-specific windows if present, credits, Banked Resets.

### Gemini
Google stopped serving Gemini CLI OAuth to individual, AI Pro and Ultra accounts in June 2026; those quotas now live in Antigravity.
1. **Antigravity CLI**: a short-lived `agy -p /usage --output-format json`, run in an empty temporary directory with logging off. It is the CLI's built-in usage command: no model turn, no tokens. `agy` uses and refreshes its own login; Tinybar never reads Google tokens.

Displayed: the "Gemini Models" 5h and weekly windows, plus Antigravity's "Claude and GPT models" 5h and weekly windows as model-specific windows. No plan name (the report has none).
Enabled automatically when `agy` and `~/.gemini/antigravity-cli` exist.

### Cursor
1. **Cursor.app login**: `cursorAuth/accessToken` from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (read-only, `immutable` when no WAL is present), sent as the `WorkosCursorSessionToken=<userID>::<token>` cookie. Skipped within 60 s of expiry.
2. **Browser cookie**: `WorkosCursorSessionToken` for `cursor.com`. Not a separate toggle: enabling Cursor is the consent (ADR 0005).
   → `GET https://cursor.com/api/usage-summary` (the dashboard's own call).

Displayed: the billing-cycle window (total plan usage), Auto and API-model windows as model-specific, on-demand spend as extra usage, reset at the cycle end.
Enabled automatically only when Cursor.app holds a login. No Limit Alerts (billing cycles are neither 5h nor weekly).

### Detection and staleness
- On launch, a Provider is enabled automatically if its CLI credentials exist. It can be toggled in Settings.
- If a fetch fails (expired token, network, 401), the Provider becomes **Stale**. It keeps its last values and says how to fix it: run `claude` once (or `codex`, `agy`, or "open Cursor or sign in at cursor.com").

Implementation note: endpoint shapes are undocumented. Verify request headers and response fields against CodexBar's sources (`Sources/CodexBarCore/Providers/{Claude,Codex}/`, `docs/codex.md`) before implementing.

## 5. Refresh policy

- A fixed 5-minute poll per enabled Provider.
- An extra refresh when the popover opens, throttled to at most once per 60 s per Provider.
- A manual refresh button (same throttle).
- Paused while the Mac sleeps or the screen is locked. On wake or unlock, refresh once.
- Per-Provider backoff when the server asks for it (`Retry-After`, 429).
- Log ingestion runs on the same poll, and when the popover opens (cheap because it is incremental).

## 6. Menu bar

- A tiny ring glyph showing how much of the Pinned Limit is **left**, in that Provider's colour (Claude orange, Gemini its spark, Codex and Cursor monochrome): full at 100%, empty at 0%, with the percentage next to it (`◕ 77%`). Settings has "hide percentage".
- **Pinned Limit**: chosen by clicking any Limit Window on a Provider page. The default is the 5h window of the first enabled Provider (order: Claude, Codex, Gemini, Cursor), or its weekly window if no 5h window exists.
- If the Pinned Limit's Provider is Stale, the glyph is dimmed.

## 7. Popover (344 × 540 pt, fixed; long pages scroll inside)

Two levels, one click apart. A tab bar at the top always shows Overview plus one tab per enabled
Provider (keys 0–4). The popover keeps one fixed size; pages sit side by side and slide into
view, so switching never rebuilds or resizes anything. Long pages scroll inside.

1. **Overview**:
   - One row per Provider: concentric rings (outer: longest account-wide window, inner: the next),
     name, plan, the window closest to running out with its reset countdown (or, in orange, the
     earliest Run-out Time), and its % left.
     Model-specific windows are left out. A Stale Provider shows "Login expired" (or the reason) in
     orange. Clicking a row opens its page.
   - Usage for all Providers (Today, 7d, 30d): total tokens, Theoretical Cost, a daily chart stacked
     by Provider, and top models and Projects, each bar split by Provider.
   - Colours come from each logo: Claude orange, Codex monochrome (black or white), Gemini its
     four-colour spark, Cursor grey.
2. **Provider page**:
   - Large rings with the tightest % left, name and plan.
   - A banner when Stale: what went wrong and what the user runs to fix it.
   - Every Limit Window: bar, % left, reset time and countdown, and its Run-out Time: in orange if
     it comes before the Reset, faint if after (the headroom). Click to pin; the pinned one is marked.
   - Extras: credits, Banked Resets, extra usage or on-demand spend.
   - That Provider's usage only: tokens, cost, chart, top models and Projects. Today is provisional.
3. **Footer**: last check time, check now (⌘R), Stats (⌘S, §13), how Tinybar counts (⌘I), settings
   (⌘,), quit (⌘Q). "How Tinybar counts" is a page like Settings: where limits, tokens, API
   prices and Stats come from, what stays on the Mac, and how much of the last 30 days' tokens
   Activity was counted from when that is short of all.

**Settings** (replaces the page, back with Esc): Provider toggles, launch at login, notifications, the browser cookie fallback per Provider (off by default; enabling it may trigger a macOS Keychain prompt for the browser's storage key), and hide percentage.

### Run-out Time
- Pace = % used ÷ time since the window started (Reset minus duration). Run-out Time = now + % left ÷ pace.
- Always shown on the Provider page; only a Run-out Time before the Reset warns (orange, and on the
  Overview).
- The window's own average needs no stored history and already includes the idle hours and nights
  that recur before the Reset.
- No forecast before 5% of the window has passed (1% steps make early readings noise), for an
  untouched or used-up window, without a reset time or duration, or while the Provider is Stale.

## 8. Limit Alerts

- Scope: the 5h and weekly Limit Windows of every enabled Provider (not model-specific windows).
- Notify once when a window crosses **90%**, and once when it crosses **95%**.
- Notify on **Reset** only if that window crossed 90% before resetting.
- De-duplicate per (Provider, window, reset time), so a notification never repeats within one window cycle, including across app restarts.
- Ask for notification permission once, on first launch.

## 9. Token history

### Sources
- **Claude**: `~/.claude/projects/**/*.jsonl`. Assistant messages with `usage` (input, output, cache creation, cache read), `model`, `timestamp`, `cwd`. De-duplicate by message id; the same response can appear several times, and the most complete copy wins.
- **Codex**: `~/.codex/sessions/**` (and archived sessions). Token counts are cumulative per session, so store deltas and handle forked sessions without double counting.

Parsing rules must be verified against CodexBar's `Sources/CodexBarCore/Vendored/CostUsage/` before implementing.

### Ingestion
- **First launch**: import all available logs once, in the background at low priority (`.utility`), with progress shown in the popover.
- **Afterwards**: incremental. Store per file (path, inode, size, mtime, byte offset). Only read appended bytes. Re-read a file from zero if it was truncated or replaced.
- Stored daily totals survive the CLIs deleting old logs (Claude Code deletes after 30 days by default).

### Store (SQLite, `~/Library/Application Support/Tinybar/usage.sqlite`; ADR 0003)
- `daily_usage(day, provider, model, project, input, output, cache_write, cache_read)`, primary key (day, provider, model, project).
- `file_cursor(path, inode, size, mtime, offset)`.
- `claude_message(id, …, stats)`: the tokens and Activity counted per Claude message id, for de-duplication. Ids older than 90 days are pruned once a day; daily totals are kept.
- `daily_stat(day, provider, model, key, value)`: Activity counters (§13, ADR 0006), sums except `context.max`. Every counter is kept per model, including `hour.HH` (responses started in that hour) and `tokens.hour.HH` (their tokens).
- `claude_event(id, day)`: Claude Prompts, edit results and Compactions already counted, pruned with message ids.
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

## 10. Theoretical Cost (ADR 0004)

- Prices (input, output, cache write, cache read per model) come from **models.dev**, fetched at most once per 24 h with a single unauthenticated GET. The last successful response is cached on disk.
- No bundled price table. If no prices have ever been fetched, or a model is not listed, show "—". Never guess from a similar model.
- Always use **current** prices, computed from stored token counts at display time.
- Theoretical Cost is not what the user paid; the UI labels it "API-equivalent".

## 11. Distribution

- Public GitHub repo `ThiloReintjes/tinybar`, MIT license.
- Pushing a `v*` tag publishes a GitHub Release with a zipped app and bumps the cask in the
  `ThiloReintjes/homebrew-tinybar` tap. `Scripts/install.sh` installs it and guides the first launch.
- Until an Apple Developer account is available, releases are ad-hoc signed, so macOS asks the user
  to approve the first launch. With an account: Developer ID signing and notarization
  (`build-app.sh` supports both), then the official cask (`brew install --cask tinybar`; Homebrew
  rejects casks that fail Gatekeeper) and Sparkle with an EdDSA-signed appcast.
- First run needs no configuration: auto-detect Providers, launch at login, request notification permission.

## 12. Later (explicitly deferred)

Grok and Kimi providers; token history for other CLIs; multiple accounts; token refresh (would need a new ADR); historical pricing; Activity for Gemini and Cursor (no local logs).

## 13. Stats window

A separate window for numbers that are fun rather than actionable, built to be shared as a
screenshot. Claude Code and Codex only. Opened from the popover footer (⌘S); built when opened and
released when closed, so it costs nothing otherwise. Activity is counted at ingest (ADR 0006).

**Layout**: one fixed 960 × 600 card under a title bar row with the range (7 days, 30 days, All
time) and **Copy image**, which puts the card on the clipboard at 2× in the current appearance. The
card opens with the Tinybar mark and name on the left and its date span on the right, and never
shows project names.

- **Tokens** in full digits, coloured by each Provider's share (Claude orange, Codex ink), with
  Theoretical Cost, the share legend and a bar chart. 7 and 30 days have a bar per day; All time
  picks the bar so the chart stays readable: a day up to 92 days, a week (Monday to Sunday) up to
  78 weeks, then a month. A caption says which.
- **Agent Time**, also as full-time weeks of 40 hours (or full workdays of 8 hours below a week).
- **Tool Calls**, also per Prompt.
- **Lines added** by file edits (Claude Code's Edit, Write and MultiEdit results; Codex file
  changes and `apply_patch`), with lines removed. Files changed through shell commands aren't seen.
- **Prompts**, with model responses per Prompt.
- **When your agents work**: tokens by weekday and local hour, with the busiest slot.
- **Tool Calls by kind**: shell commands, web lookups, MCP tools, file reads, file edits, code
  searches, subagents; each bar split by Provider.
- **Models**: the top four by tokens, with average Output Speed and peak context. "All N" opens
  every model in the range, by Provider, in a popover.
- **Facts**: current and longest Streak, busiest day, share of input read from cache, Compactions
  (and tokens they summarized, Claude), biggest context, Projects and active days.

**Model filter**: clicking a model in the card or in the full list shows that model alone
everywhere except the model list; clicking it again or Escape goes back. A model from the full list
takes a fifth row kept free for it. The Streak then counts that model's days. Changing to a range
the model wasn't used in goes back to all models. The copied image shows the filter as it is.

**Nothing moves**: filtering or new data changes values, never positions. The token count is sized
to all models' total for the range, every section keeps its rows (empty ones included), and the
numbers and bars animate to their new values (not with Reduce Motion).

**Details on hover**: pointing at a piece of the card shows its figures and what it means, right
away, without moving anything else: a bar's tokens by Provider, cost, Prompts, Tool Calls, Agent
Time and lines; a heat map cell's tokens and responses, summed over the range's weekdays of that
name; a tool kind's split by Provider and its most used tool names; a model's tokens, share, cost,
responses, speed and how many responses it was timed over; the definitions of the headline numbers
and facts; the top Projects by name. The hovered bar, cell or tool row stays lit and the others
dim. The copied image has no hover state.

### What counts
- **Prompt**: a Claude Code user line that is typed text (not a tool result, `isMeta`, a compact
  summary, a sidechain or a notification) and is answered: the next main-thread response before
  another Prompt counts it, under that response's model. Codex: a user message outside subagent
  sessions, under the turn's model.
- **Model of other Activity**: a Claude response's own (tool calls, timing); an edit result's is the
  model that made the call; a Compaction's the latest response's. Codex: the turn's model. GPT
  models run inside Claude Code count under Codex, as their tokens do.
- **Tool Call**: Claude Code `tool_use` blocks, deduplicated by their id (MCP tools stored as
  `MCP`). Codex `item_completed` actions (command, file change, web search, MCP call), or in
  older versions the named tool calls. `exec`/`js` wrappers are not Tool Calls themselves.
- **Agent Time**: Claude: for each response, the time from the step's start (the Prompt, or the
  end of the previous response, so tool execution counts) to its last line; steps over 30 minutes
  are left out as waiting. Codex: each turn's `duration_ms`.
- **Output Speed**: output tokens ÷ (last line − request sent) for responses of 200+ output tokens
  taking 1 s to 10 min, summed per model; shown from 10 samples. The request is the last user
  line before a Claude response, or the last tool output or turn start before a Codex
  `token_usage_record`.
- **Compaction**: Claude `compact_boundary` lines (tokens summarized = before − after); Codex
  `ContextCompaction` items.
- **Context**: input + cache write + cache read of one response.
- Lines over 1 MB are skipped, as for tokens.

### Upgrades
A database from a version without Activity is backfilled once, in the history import's child
process: every log is re-read up to its saved offset for Activity only. Token totals and offsets
are untouched. Activity from logs no longer on disk (deleted, or archived by the CLI) can't be
recovered, so those sessions show tokens but no Activity; "How Tinybar counts" says how much of
each Provider's tokens the counted logs hold. Codex compresses older sessions to `.jsonl.zst`,
which Tinybar doesn't read.

0.2.0 kept Prompts, Tool Calls, lines, Agent Time and Compactions without their model. Its
counters are cleared once (schema 4) and recounted the same way, per model.
