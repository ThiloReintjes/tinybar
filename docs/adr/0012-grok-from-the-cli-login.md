# Read Grok's limits with the CLI's login, and one bar for its pool

Grok is the next Provider SPEC had on its list, and [issue #18](https://github.com/ThiloReintjes/tinybar/issues/18) asked for it. T3 Code and CodexBar read the same undocumented call the CLI makes for `/usage`, so Tinybar does too: `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`, with the `key` from `~/.grok/auth.json`. The CLI is open source, which is why the shapes here are known rather than guessed.

Since June 2026 a paid plan has one weekly pool that Chat, Build, Imagine and the rest draw from. `productUsage` is each one's share of that pool, adding up to the total, so showing them as bars would present shares as limits. There's one bar, as in T3 Code. CodexBar lists the shares as text, which can come later.

The rules come from reading all three clients and running the real CLI:

- **Which login.** Only the two entries the CLI's installer names, as T3 Code does, since other deployments can sit in the same file and CodexBar's prefix match can't say which it picks. `auth_mode` `api_key` bills elsewhere, and the CLI ignores `web_login` and its older name `grok`, so neither counts. A custom deployment (T3 Code's list of config sections and variables) is left to the CLI, as the file's login may not be the account it uses.
- **Never renewing.** `auth.json` holds a refresh token that the CLI's own source says can be used only once, so ADR 0001 matters more here than anywhere: using it could sign the user out. A login past `expires_at` sends nothing and goes Stale until `grok` runs. CodexBar reports tokens lasting about seven days, so anyone using Grok less than weekly will see this often. That's accepted, as ADR 0001 says.
- **A left-out percentage is zero, but only within a whole typed period.** proto3 leaves zeros out, as T3 Code notes, while a report on the older billing bounds counts its use in other fields. A value that's present and unreadable fails the report instead, so a change in the format can't read as a full pool.
- **An ended period is no reading.** With one Account, nothing downstream catches a Reset already past, so it would show as a fresh number resetting "now". It goes Stale with a message instead, and if xAI only rolls a period over on use, an idle pool stays Stale until then.
- **Plan name.** Not in the billing report, so it comes from `/v1/settings`, as the CLI and CodexBar do. It's optional: the limits show without it.
- **Team accounts.** CodexBar finds their usage turned away, so a 400, 403 or 404 for a team says that rather than "login expired". The request is still sent, so if xAI starts answering, it shows.
- **Extra usage.** `onDemandUsed` of `onDemandCap`, in US cents by the CLI's source. A zero pair is what most accounts send, and shows nothing.
- **Status.** CodexBar says xAI has no feed, but `status.x.ai/api/status` is what the page itself reads, and answers plain requests. Only `grok.com` counts, as Imagine and Voice say nothing about coding and the page lists nothing for the CLI.

## Considered options

- **Running `grok agent stdio` for `_x.ai/billing`**, as CodexBar does first, which keeps the token out of Tinybar and would also renew an old login. But the binary is 180 MB to start every 5 minutes, it makes four other requests as it starts, and a login being renewed by polling is what ADR 0001 rules out. Its method name has also moved: `x.ai/billing` answers "Method not found".
- **grok.com's billing call with browser cookies**, which would serve people who only use grok.com. CodexBar has it, but it now needs a key held by the browser, so cookies alone can fail, and it adds cookie access for a route that's already breaking.
- **Local session files** for token history (`~/.grok/sessions`). They hold token counts with no per-model split, so there's no Theoretical Cost to give. Left out, like Copilot's.
- **xAI's management API** for prepaid API balance. That's a different bill from the subscription, and needs a key the user would have to paste.
- **Reset coupons** (`GetRemainingResets`): an undocumented grok.com call on top, for a display-only count.
- **The `prepaidBalance`**: the app's Credits line has no currency, so a dollar balance would read as a count. Easy to add if someone asks.

## How it was tested, with no plan

The owner has no Grok account, so `Scripts/verify-grok.py` runs the real CLI (1.0.70, checked to be signed by xAI) against a local mock, using the CLI's own `GROK_CLI_CHAT_PROXY_BASE_URL`. Its client and Tinybar read the same responses and must agree, and logins the CLI refuses must be left alone. The reports follow live payloads CodexBar's users captured. The script also sends an invalid token to the live endpoints, directly and through Tinybar, and reads the live status page. That found what fixtures wouldn't have, or settled what the sources disagreed on:

- The live timestamps have microseconds and `+00:00`, which the existing date parser reads.
- `x.ai/billing` is `_x.ai/billing` on the wire, in 1.0.70.
- The live endpoints answer an invalid token with 401 and `{"error": …}`.
- The real CLI accepts a login under the older scope, and refuses the old web logins and an API key for billing, as its source says.
- `status.x.ai` answers `/api/status` and `/api/incidents` while blocking most other paths.

## Consequences

- **Never checked against a real plan.** The shapes come from the CLI's source, its real client, and payloads CodexBar's users posted. The first person with a plan should run `swift run tinybar-cli limits --provider=grok`.
- **The login file is second-hand.** It's the CLI's `GrokAuth` from its source, which the real CLI reads and uses, but a real `grok login` needs an account. The scope's client id is from the CLI's installer. If xAI changes it, Tinybar says "Not signed in" until updated.
- **People who only use grok.com get nothing**, as there's no login to read. The pool would mean something to them, but the cookie route above isn't worth it.
- **Other account types are unknown.** What a team gets comes from CodexBar's docs, not from a response seen here. What a free account gets isn't known at all: a report with no percentage to read says "no usage limit". Whether new X Subscription accounts answer the same isn't known either.
- **Only `available` has been seen on the status page.** Other words are matched by what other pages use, and one nobody knows keeps the last answer rather than clearing an outage or inventing one.
- It's undocumented, and can change with any CLI release. A failure shows as Stale rather than a wrong number.
- One Account for now, the CLI's own.
- No Limit Alerts on a monthly period, like Copilot's. Weekly ones have them.
