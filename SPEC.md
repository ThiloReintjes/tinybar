# Tinybar — v1 Specification

A lightweight, native macOS menu bar app showing AI subscription limits, local token usage over time, and the Theoretical Cost of that usage. It is a from-scratch alternative to [CodexBar](https://github.com/steipete/CodexBar) (about 309k LOC, 87 providers), built around performance and a small scope.

Vocabulary: see [CONTEXT.md](./CONTEXT.md). Decisions: [docs/adr/](./docs/adr), above all [ADR 0001](./docs/adr/0001-read-only-credentials.md) (read-only credentials).

## 1. Goals and non-goals

**Goals**
- A one-command install that runs with zero configuration.
- Near-zero resource use (see §2).
- Accurate Limit Windows, Resets and Banked Resets for Claude, Codex, Gemini, Cursor and OpenCode Go.
- Daily token history and Theoretical Cost from local CLI logs.
- Publishable: MIT license, notarized, auto-updating.

**Non-goals (v1)**
- Providers other than Claude, Codex, Gemini, Cursor and OpenCode Go. Grok and Kimi come later, one at a time.
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
- Plain SwiftPM, no dependencies (ADR 0002). Updates go through Homebrew (ADR 0007).
- Launch at login via `SMAppService`, on by default.

## 4. Providers (v1)

For each Provider, the source order is inspired by CodexBar and everything is strictly read-only (ADR 0001).

### Claude
1. **CLI OAuth**: read the token from `~/.claude/.credentials.json`, else Keychain item `Claude Code-credentials`.
   → `GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1`, with the same headers the official CLI sends. `cedar_ember=1` adds the Banked Resets ("Reset for free" grants), as claude.ai asks for them. The plan name comes from the subscription type the CLI stores with its token. An account it isn't open to answers 400 or 403; then the plain request is sent once. Grant ids are redemption handles and are never read; only grants that are not paused, have resets left and are inside their start and end count, once per reset left.
2. **Browser cookie fallback** (opt-in in Settings, ADR 0005): `sessionKey` from Chromium browsers or Firefox → `claude.ai/api/organizations/{id}/usage`. Safari is out (needs Full Disk Access).

Displayed: 5h session window, weekly window, model-specific weekly windows (e.g. Opus/Sonnet), extra usage spend if present, Banked Resets, and a Reset time for each.
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

### OpenCode Go
Only the subscription: Zen's balance and Console budgets have no Limit Window (ADR 0009).
1. **OpenCode's login**: the selected `opencode-go` credential, else `opencode` (a Console login), from `opencode.db` in `$XDG_DATA_HOME/opencode` or `~/.local/share/opencode`, read-only, ordered as OpenCode does (`active DESC, time_created DESC, id DESC`). OpenCode 1.x keeps it in `auth.json` beside that database instead; a database with `session_v2` (2.x) never falls back to it. An expired login is not refreshed.
   → `GET https://opencode.ai/zen/go/v1/usage`, the request OpenCode's client makes, with `Authorization: Bearer` and, for a Console login, `x-opencode-org-id`. A login is sent only to opencode.ai or a Console on this Mac. A 403 with OpenCode's own error body means no Go subscription; the site's firewall answers 403 too, and is reported as an HTTP error.

Displayed: the 5-hour, weekly and monthly windows. A `rate-limited` window shows nothing left, whatever its share. No plan name (the report has none), and no model-specific windows: Go's limits are per model but it reports one share per window.
Enabled automatically only with an `opencode-go` credential, as a Console login may have no Go plan. No Limit Alerts for the monthly window.

### Detection and staleness
- On launch, a Provider is enabled automatically if its CLI credentials exist. It can be toggled in Settings.
- If a fetch fails (expired token, network, 401), the Provider becomes **Stale**. It keeps its last values and says how to fix it: run `claude` once (or `codex`, `agy`, "open Cursor or sign in at cursor.com", or `opencode auth login`).

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
- **Pinned Limit**: chosen by clicking any Limit Window on a Provider page; clicking it again unpins it. Unpinned, the menu bar shows **Auto**: of every Provider's account-wide windows, the one whose Run-out Time comes first before its Reset, else the one with the least left (ties: the earlier Reset). Stale Providers count only when no other is known. A pinned window that disappears falls back to Auto. Settings has "Show the limit closest to running out".
- If the Pinned Limit's Provider is Stale, the glyph is dimmed.
- **Incidents**: while any enabled Provider has an Incident that disrupts it (not maintenance), the ring wears a status light at its top right, cut out of the ring: orange when degraded, red for an outage. The tooltip names it. No animation.

### Status pages
Read on every poll and popover refresh (same throttle), without credentials, only for enabled Providers:
- **Claude**: `status.claude.com/api/v2/summary.json` (statuspage.io). Counts the components `claude.ai`, `Claude API` and `Claude Code`; Console, Cowork and Government don't count.
- **Codex**: `status.openai.com/proxy/status.openai.com` (incident.io), counting the components of the "Codex" group; when any is affected, `status.openai.com/api/v2/summary.json` supplies the incident's title (the open incident naming Codex, else the first open one with an impact).
- **Cursor**: `status.cursor.com/api/v2/summary.json`, all components.
- **OpenCode Go**: `status.opencode.ai/api/status`, its `go` service only: Zen's free models are often degraded, which says nothing about the subscription. A page reporting its own data as stale is no answer.
- **Gemini**: none. Antigravity has no status page, and Google's Workspace feed (about 350 KB) covers the Gemini app instead.
An unresolved incident counts when it names a counted component, or names none and has an impact. Its severity is the worst status among counted components (degraded, partial outage, major outage), else its impact. Maintenance in progress counts as maintenance. A page that can't be read keeps its last answer.

## 7. Popover (344 × 540 pt, fixed; long pages scroll inside)

Two levels, one click apart. A tab bar at the top always shows Overview plus one tab per enabled
Provider (keys 0–5). With all five on, a Provider page shows only its own name and the other tabs a dot, with the name on hover. The popover keeps one fixed size; pages sit side by side and slide into
view, so switching never rebuilds or resizes anything. Long pages scroll inside.

1. **Overview**:
   - One row per Provider: concentric rings (outer: longest account-wide window, inner: the next),
     name, plan, the window closest to running out with its reset countdown (or, in orange, the
     earliest Run-out Time), and its % left.
     Model-specific windows are left out. A Stale Provider shows "Login expired" (or the reason) in
     orange; otherwise an Incident shows its status light and title in its colour, ahead of the
     Run-out Time. Clicking a row opens its page.
   - Usage for all Providers (Today, 7d, 30d): total tokens, Theoretical Cost, a daily chart stacked
     by Provider, and top models and Projects, each bar split by Provider.
   - Colours come from each logo: Claude orange, Codex monochrome (black or white), Gemini its
     four-colour spark, Cursor grey, and OpenCode teal, as its mark is monochrome too.
2. **Provider page**:
   - Large rings with the tightest % left, name and plan.
   - A banner per Incident: status light, title, severity and affected components, when it was
     last updated and on which status page. Clicking it opens the incident.
   - A banner when Stale: what went wrong and what the user runs to fix it.
   - Every Limit Window: bar, % left, reset time and countdown, and its Run-out Time: in orange if
     it comes before the Reset, faint if after (the headroom). Click to pin; the pinned one is marked.
   - Extras: credits, Banked Resets, extra usage or on-demand spend.
   - That Provider's usage only: tokens, cost, chart, top models and Projects. Today is provisional.
3. **Footer**: last check time (or the update pill, §11), check now (⌘R), Stats (⌘S, §13), how Tinybar counts (⌘I), settings
   (⌘,), quit (⌘Q). "How Tinybar counts" is a page like Settings: where limits, tokens, API
   prices and Stats come from, what stays on the Mac, and how much of the last 30 days' tokens
   Activity was counted from when that is short of all.

**Settings** (replaces the page, back with Esc): Provider toggles, launch at login, notifications, the browser cookie fallback per Provider (off by default; enabling it may trigger a macOS Keychain prompt for the browser's storage key), hide percentage, and Auto for the menu bar. The running version sits at the bottom, next to a Report a bug link that opens the GitHub bug form with the version and macOS filled in.

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

- **OpenCode**: `opencode.db`, as a copy of the database and its WAL (a clone on APFS). Finished `message` rows (1.x) and `session_message` rows (2.x, assistant and compaction) whose provider is `opencode-go`; everything else is left out (ADR 0009). `output` plus `reasoning` counts as output. Forks and the upgrade to 2.x copy rows under new ids, so a response is identified by its time, model and tokens. Each read starts 10 minutes before the newest row seen, never counted past now, and is skipped while the database and WAL are unchanged. No Activity.

Parsing rules must be verified against CodexBar's `Sources/CodexBarCore/Vendored/CostUsage/` before implementing.

### Ingestion
- **First launch**: import all available logs once, in the background at low priority (`.utility`), with progress shown in the popover.
- **Afterwards**: incremental. Store per file (path, inode, size, mtime, byte offset). Only read appended bytes. Re-read a file from zero if it was truncated or replaced.
- Stored daily totals survive the CLIs deleting old logs (Claude Code deletes after 30 days by default).

### Store (SQLite, `~/Library/Application Support/Tinybar/usage.sqlite`; ADR 0003)
- `daily_usage(day, provider, model, project, input, output, cache_write, cache_read)`, primary key (day, provider, model, project).
- `file_cursor(path, inode, size, mtime, offset)`.
- `claude_message(id, …, stats)`: the tokens and Activity counted per Claude message id, for de-duplication. Ids older than 90 days are pruned once a day; daily totals are kept.
- `opencode_message(key)`: the OpenCode responses already counted, kept for good as a fork can copy a message of any age.
- `daily_stat(day, provider, model, key, value)`: Activity counters (§13, ADR 0006), sums except `context.max`. Every counter is kept per model, including `hour.HH` (responses started in that hour) and `tokens.hour.HH` (their tokens), `cmd.*` (Shell Commands: `cmd.prog.<program>`, `cmd.git.<subcommand>` and habit counts) and `ext.added|removed|edits.<extension>`.
- `claude_event(id, day)`: Claude Prompts, edit results and Compactions already counted, pruned with message ids.
- `daily_long_context(day, provider, model, project, band, …tokens)`: the part of `daily_usage` from long requests, for Long-context Prices (§10).
- `limit_reading(provider, window, resets_at, duration, plan, used_bp, read_at, plan_changed)`: the highest share of each weekly Limit Window seen, the newest 8 per window (§14).
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
- **Long-context Prices**: models.dev lists context tiers (`cost.tiers`, `type: "context"`; older entries `context_over_200k`). A request whose context (input + cache write + cache read) is over a tier's size is priced at that tier entirely. When read, each request over 100K is filed in one **Context Band**, the largest of 100K, 200K, 272K, 400K and 1M its context exceeds. At display time a band takes the highest tier at or below its size, so a tier at a band size is exact and one between bands applies from the next band up.
- The prices cache records its format; a cache from before tiers is used but fetched again at once.
- Theoretical Cost is not what the user paid; the UI labels it "API-equivalent".

## 11. Distribution

- Public GitHub repo `ThiloReintjes/tinybar`, MIT license.
- Pushing a `v*` tag publishes a GitHub Release with a zipped app and bumps the cask in the
  `ThiloReintjes/homebrew-tinybar` tap. `Scripts/install.sh` installs it and opens it.
- Releases are signed with Developer ID and notarized, so Gatekeeper opens them without asking.
  The release workflow stops if signing or notarization fails. Next: the official cask
  (`brew install --cask tinybar`).
- **Updates** (ADR 0007): once a day, `GET api.github.com/repos/ThiloReintjes/tinybar/releases/latest`;
  an hour after a check that got no answer, and right away when Tinybar's own version changes.
  A newer version replaces the footer's check time with "Update to x.y.z" and is notified once
  (with Limit Alerts' setting). Clicking it, for a Homebrew install: pull the tap, check the cask
  lists that version, `brew fetch` it ("Updating…"), then hand over to a script that waits for
  Tinybar to quit, runs `brew upgrade --cask thiloreintjes/tinybar/tinybar` and opens the app. On
  failure the old version reopens with "Update failed"; clicking that copies the command. Other installs open the release page.
- First run needs no configuration: auto-detect Providers, launch at login, request notification permission.

## 12. Later (explicitly deferred)

Grok and Kimi providers; token history for other CLIs; OpenCode usage routed to other subscriptions; Activity for OpenCode; multiple accounts; token refresh (would need a new ADR); historical pricing; Activity for Gemini and Cursor (no local logs).

## 13. Stats window

A separate window for numbers that are fun rather than actionable, built to be shared as a
screenshot. Claude Code and Codex only. Opened from the popover footer (⌘S); built when opened and
released when closed, so it costs nothing otherwise. Activity is counted at ingest (ADR 0006).
The window opens centered, remembers its position, and recenters saved positions outside the visible
screen. ⌘W closes it.

**Layout**: fixed 960 × 600 cards under a title bar row with the pages (Overview, Commands,
Models, Languages, Plans; ⌘1 to ⌘5, the last one remembered), the range (7 days, 30 days, All time) and
**Copy image**, which puts the current card on the clipboard at 2× in the current appearance. The
tabs aren't part of the card. Each card opens with the Tinybar mark, name and (but for the
overview) its page on the left and its date span on the right, and never shows project names. A
new page slides in from the side its tab sits on (a cross-fade with Reduce Motion).

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

**Commands**: Shell Commands as one number split by Provider; the programs they run (share of
commands, split by Provider; git's subcommands on hover); and each model's habits, ranked: piped
into `head` or `tail`, `grep` rather than `rg`, programs written inline (Python solid, JavaScript
light), average command length, non-zero exits, `git status` per `git commit`.

**Models**: each model ranked by average Output Speed, responses per Prompt, Agent Time per
Prompt, responses that run tools in parallel, lines added per Prompt and peak context.

**Languages**: lines added as one number split by Provider; Languages by lines added, each in a
fixed colour; what each model writes (its lines split by the six most written coloured
Languages, the rest grey); file edits, lines removed, lines per edit and the most written
Language.

A model shows up in a ranking once it has enough data in the range: 10 Prompts, 50 responses,
30 Shell Commands, 20 `grep` or `rg` commands, 5 commits, 50 lines, or 10 speed samples.

**Model filter**: clicking a model in the card or in the full list shows that model alone
everywhere except the model list; clicking it again or Escape goes back. A model from the full list
takes a fifth row kept free for it. The Streak then counts that model's days. Changing to a range
the model wasn't used in goes back to all models. The copied image shows the filter as it is. On the Commands and Languages pages the totals filter
the same way; every ranking keeps all models and lights the picked one's row instead (a picked
model with too little data for a ranking says so in its last row). On the Models page it only
lights rows.

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
- **Shell Command**: a Claude Code `Bash` call's `command`; a Codex `CommandExecution` item's
  `command` (the script of `bash -lc`), or an older version's `shell` call. Split at `|`, `||`,
  `&&`, `;`, `&`, newlines, parentheses and backticks outside quotes, skipping heredoc bodies and
  comments; each part's program is its first word after variable assignments, redirections,
  keywords and wrappers (`sudo`, `env`, `timeout`, `time`, `nohup`), as a lowercased basename
  (`python3.12` is `python`). Shell builtins aren't programs; saved scripts (`.sh`, `.py`, …) are
  `script`. Each program counts once per command. Inline: `python -c`, `python -`, a heredoc fed
  to Python, `node|bun|deno -e|-p|--eval`. Exit: Claude results whose error starts "Exit code"
  (blocked or denied calls aren't failures); Codex `exit_code`. Older Codex versions don't log it.
- **Parallel**: a Claude response with more than one `tool_use`; a Codex `exec` or `js` script
  with `Promise.all` (Codex makes one call per response).
- **Language**: an edited file's extension (Claude Code's `filePath`; Codex change paths and patch
  headers), named for display. A Codex change to several files counts as one edit per file.
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
counters are cleared once (schema 4) and recounted the same way, per model. 0.3.0 had no Shell
Commands, Languages or parallel counts; schema 5 clears and recounts once more.

Schema 8 adds `opencode_message`. A store from before it reads OpenCode's history once, in the child
process, before normal ingestion does.

Schema 7 adds `limit_reading`.

Schema 6 (0.5.0) adds Context Bands. Claude's come at once from the message ids kept for
de-duplication (90 days); Codex logs still on disk are re-read once, in the child process, up to
their saved offsets, for long requests only. Older days stay at base prices.

A backfill reads each file only up to the offset it had when the backfill was first armed, and
records each finished file, so an interrupted one resumes without counting anything twice while
normal ingestion carries on. Migrations run in one transaction. Before 0.5.1, GPT responses
logged by Claude Code were counted from the largest value of each field across their streamed
copies, which counted cached context twice; stored totals from those days are not rewritten, but
a message seen again is replaced by its complete copy.

## 14. Plans (ADR 0008)

A page of the Stats window, for Claude and Codex (Gemini and Cursor have no token logs, and OpenCode Go limits differ by model at the same price, ADR 0009). It turns
each weekly Limit Window into API dollars, then compares the models. The range picker doesn't apply
and hides.

- **Reading**: after each ingest, a fresh snapshot's weekly account-wide window updates its
  `limit_reading` row when its share rises, with the time of that reading. A Reset within an hour of
  the stored one is the same window. A plan change marks the window. Only Tinybar's own polls are
  read, so a user's history starts with this version.
- **A window's value**: Theoretical Cost from its start (Reset minus duration) up to now while it's
  open, or to its last reading once it's over, ÷ share used × 100. A day partly inside takes the
  share of its tokens from `tokens.hour.HH`, per model, assuming tokens fall evenly in an hour.
- **Full week**: the median of up to 8 windows on the current plan with at least 10% used and no
  plan change. Below 10%, 1% steps are too coarse. Nothing is shown before one window qualifies.
- **Per $1**: full week × 4.35 weeks ÷ the plan's list price in US dollars. Every window is assumed
  used in full; Banked Resets and other extra resets aren't counted. A plan with no known price
  drops this figure.
- **Models**: a table bundled with the app holds each current model's Artificial Analysis
  Intelligence Index score, cost per Benchmark Task and minutes per Benchmark Task, at maximum
  effort, with the date it was copied. Tasks a week = full week ÷ cost per Benchmark Task, which
  assumes the limit counts every model at its API price. Models are listed by score.
- **Your use**: the last 7 days' Theoretical Cost, today included, as Usage's 7d shows it, and each
  model's share of it. Per $1 at your pace = that × 4.35 ÷ the list price. A meter shows it against a
  full week, full at or above one; going over can follow an early reset.
- **Display**: a column per plan, then one comparison of every model. Each column has two large
  numbers of equal weight, API usage per $1 at your pace and if you use it all (without a known
  price, the last 7 days' and a full week's dollars); the meter; and, with a known price, the total
  dollars of both. Below, the heading links to the index, with a plain list of each model's score and
  tasks per week beside a chart of one against the other. The chart has score 20 to 60 up and tasks
  across on a log scale fitted to the models. Marks are circles for Claude and squares for Codex,
  filled when used in the last 7 days (5% or more) and outlined otherwise. Pointing at a row or a
  mark shows the full figures and dims the rest. Estimates keep two significant figures, and a +
  marks a figure with use that has no known price.
- **How this is worked out**: a button at the bottom opens the workings, the assumptions and the
  source in a popover. The copied image leaves it out.
