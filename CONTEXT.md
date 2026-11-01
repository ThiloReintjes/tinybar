# Tinybar

A macOS menu bar app that shows how much of each AI coding subscription is used up, how many tokens were used over time, and what that usage would have cost at API prices.

## Language

### Subscriptions and limits

**Provider**:
A company whose AI subscription Tinybar tracks (e.g. Anthropic via Claude, OpenAI via Codex, Google via Gemini, Anysphere via Cursor, OpenCode via its Go subscription).
_Avoid_: Service, vendor, integration

**Limit Window**:
A rolling or fixed period in which a Provider caps usage, shown as the percentage left (100% at the start of the window, 0% when the cap is reached) and a Reset time (e.g. the 5-hour session window, the weekly window, a model-specific weekly window).
_Avoid_: Quota, rate limit, bucket

**Reset**:
The moment a Limit Window's usage returns to zero.
_Avoid_: Renewal, refresh

**Run-out Time**:
When a Limit Window will reach 0% left if usage continues at its average pace since the window started. It can fall after the Reset; then the limit doesn't bind and the gap shows the headroom.
_Avoid_: ETA, prediction, burn rate

**Banked Reset**:
A saved reset the user holds (a Codex reset coupon, a Claude "Reset for free" grant), which can be redeemed to reset a Limit Window early. Tinybar only displays it and never redeems it.
_Avoid_: Reset credit, rollover

**Pinned Limit**:
The single Limit Window the user picked in the popover to show in the menu bar. Without one, the menu bar shows Auto: the account-wide window that runs out first.
_Avoid_: Primary limit, featured limit

**Incident**:
A problem a Provider reports on its own public status page that affects the parts Tinybar's users rely on (for Claude: claude.ai, the API and Claude Code), from degraded service to a major outage, or maintenance in progress.
_Avoid_: Outage (it's one severity), downtime, alert

**Limit Alert**:
A macOS notification sent when a 5-hour or weekly Limit Window crosses 90% or 95% used, or when it Resets after having crossed 90%.
_Avoid_: Warning, reminder

**Stale**:
The state of a Provider whose latest data could not be fetched (e.g. an expired login). Its last known values are shown with the time they were fetched.
_Avoid_: Offline, error state

### Token history

**Usage Record**:
A single model response from a local coding CLI log or database, with its token counts (input, output, cache write, cache read), model, timestamp and Project.
_Avoid_: Event, entry, log line

**Project**:
The code repository a Usage Record was produced in, identified by the git repository that contains the working directory.
_Avoid_: Workspace, folder, cwd

**Provisional Day**:
A local calendar day whose totals may still grow because CLI logs are written late. A day becomes final one hour after its midnight.
_Avoid_: Open day, pending day

**Theoretical Cost**:
What a set of Usage Records would have cost at the Provider's public API prices. It is not what the user actually paid.
_Avoid_: Spend, cost, bill

**Long-context Price**:
The higher API price a Provider charges for a whole request whose context is over a size (272K tokens for current GPT models).
_Avoid_: Tier pricing, surcharge

**Plan Value**:
What a subscription's weekly Limit Window would cost at the Provider's API prices, measured from the user's own limits and logs: Theoretical Cost since the window started ÷ share used. It is a floor, because use outside the logged CLIs takes up the limit too.
_Avoid_: Worth, ROI, savings

**Benchmark Task**:
One job from the Artificial Analysis Intelligence Index, which that benchmark prices and times per model. It describes the benchmark, not the user's work.
_Avoid_: Task (alone), job

### Activity

**Activity**:
What the agents did, read from the same local logs as Usage Records: Prompts, Tool Calls and Shell Commands, lines added and removed by Language, Compactions, Agent Time and Output Speed. Claude Code and Codex only. Each piece belongs to the model that produced it.
_Avoid_: Telemetry, metrics, analytics

**Prompt**:
A message the user typed into Claude Code or Codex that a model answered; it belongs to the model that answered it. Local commands that never reach a model (`/model`, `/clear`), messages that got no answer before the next one, tool results, injected context, background-task notifications and messages between agents are not Prompts.
_Avoid_: Request, query, turn

**Tool Call**:
One action an agent takes through a tool: a shell command, a file edit or read, a code search, a web lookup, a subagent, an MCP tool.
_Avoid_: Action, function call, step

**Shell Command**:
One command line an agent ran in a shell, a Tool Call of its own. Only the programs it runs are kept (`git`, `rg`, `python`), never its arguments; a saved script counts as `script`. A Codex script that runs several commands is several Shell Commands.
_Avoid_: Bash call, exec

**Language**:
What an edited file is written in, from its extension (`.tsx` is TypeScript). An extension without a known language stays itself (`.body`).
_Avoid_: File type (in the UI)

**Compaction**:
A CLI summarizing a session's context to make room, by itself or on request.
_Avoid_: Context reset, summarization

**Agent Time**:
How long the agents worked: from a Prompt to the end of the agent's last step in that turn, tool execution included. Parallel sessions and subagents add up, so it can exceed the hours in a day.
_Avoid_: Session time, runtime, compute time

**Output Speed**:
A model's output tokens per second, from sending a request to its last token, over responses of at least 200 output tokens. It includes the wait for the first token.
_Avoid_: Throughput, latency, tokens per second (without saying how it is measured)

**Streak**:
Consecutive local calendar days with any Usage Records.
