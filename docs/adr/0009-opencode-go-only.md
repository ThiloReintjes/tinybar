# Track OpenCode Go, not OpenCode

OpenCode is a CLI that runs on many backends, and a company with several offers. Only OpenCode Go is a subscription with Limit Windows, so the Provider is OpenCode Go. Zen's pay-as-you-go balance and Console budgets have no window to show.

Token history follows: only messages whose `providerID` is `opencode-go` count. A message routed to Claude or ChatGPT uses that subscription, but the row doesn't say whether it was a subscription or an API key, and OpenCode's Claude agent may log to Claude Code's transcripts too. Counting those would skew Plan Value and might count them twice.

The limits come from the request OpenCode's own client makes, with the login it already keeps. Browser cookies, which CodexBar also reads, would add a second login path and two Console API generations for little: anyone using Go through OpenCode has a login. Activity is left out for now, so the Stats window stays Claude Code and Codex only, as a token count without prompts or tools behind it would read as missing logs.

OpenCode keeps a database rather than logs, so reading it differs from the other sources:

- A response is identified by its time, model and tokens, not its id. A fork copies messages under new ids and keeps no link to the original, and the upgrade to 2.x leaves copies in the old table. Rows that aren't finished don't count, so a key never changes. Two real responses with the same millisecond, model and token counts would count once; nothing tells them apart from a fork, and all six values matching is rare enough to accept.
- Each read starts 10 minutes before the newest row seen, for rows other sessions commit late. Counting is by key, so reading a row twice is harmless, which also lets a replaced database start over and a read during a checkpoint not move on.
- A database that can't be read as expected adds nothing and retries on the next poll, since its schema is OpenCode's internal business.

## How it was tested, with no subscription

We don't pay for Go, so `Scripts/verify-opencode.py` runs the real OpenCode 1.x and 2.x against a local mock of the Go API. The real CLIs write the rows and logins Tinybar reads. For limits, OpenCode's own client and Tinybar read the same responses and must agree, which keeps the mock honest. Doing this found what no document said and CodexBar's fixtures don't show:

- 1.x has an empty `credential` table and keeps the key in `auth.json`.
- An upgraded login has `active = NULL`. OpenCode then picks the newest row.
- 2.x leaves `auth.json` behind, even after logging out.
- `output` excludes `reasoning`, which is billed as output.
- The site's firewall answers 403 to clients it blocks, the same status as "no Go subscription".

## Consequences

- **Never checked against a real subscription.** The report's shape comes from OpenCode's source and tests, and its real client accepted it, but no real account has returned one. That a Go key (rather than a Console login) is accepted by the usage endpoint comes from CodexBar only. The first person on Go should run `swift run tinybar-cli limits --provider=opencode`.
- A real 403 body is only known from OpenCode's tests as `{"type":"error"}`. If the real one differs, a user without Go sees "OpenCode API returned HTTP 403", which is true but less helpful. Console logins are opt-in partly for this reason: auto-enabling them would show this to everyone signed in to OpenCode without Go.
- The endpoint isn't documented publicly, and neither is the database, so either can change without notice. Pinned versions in the script make a re-run after an OpenCode release the way to find out.
- `metadata.server` on a login is honored only for opencode.ai and this Mac, while OpenCode's client sends it anywhere. A self-hosted Console would not work.
- Plan Value is left out: Go's limits are per model, so GLM-5.3 and GLM-5.2 cost the same and use up the limit at four times different rates. Dollars per share used would mostly measure the model mix.
- Go has no Limit Alerts for its monthly window, like Cursor's billing cycle.
