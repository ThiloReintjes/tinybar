# Read Copilot's limits with the logins already on the Mac

GitHub Copilot is popular enough to track, but it has no single login to read. VS Code keeps its own encrypted, the Copilot CLI keeps one in the Keychain, and CodexBar solves this with a sign-in of its own, which ADR 0001 rules out. So Tinybar reads what is already there, in this order:

1. **The Copilot CLI's current user**, from `~/.copilot/config.json`, with its token from that file (where the CLI has no Keychain) or else from `gh auth token --user <login>`. T3 Code runs Copilot through this CLI, and `gh` is the CLI's own documented fallback.
2. **The Copilot CLI's Keychain item** (`copilot-cli`, account `host:login`) if the user turned Copilot on themselves. Unlike Claude's and `gh`'s items, its access list names only the Copilot binary, so `/usr/bin/security` makes macOS ask.
3. **An editor plugin's login**: `~/.config/github-copilot/apps.json`, then `hosts.json` (JetBrains, Neovim and others).
4. **`gh`'s active user** if the user turned Copilot on themselves.

Auto-detection covers what needs no prompt and says Copilot is in use: a CLI user whose token is in its file or held by `gh`, or an editor plugin's login. A `gh` login alone isn't enough, as it would put a "no Copilot plan" card in front of everyone signed in to GitHub. VS Code users turn Copilot on in Settings and it reads `gh`, like Cursor's browser session (ADR 0005). A `gh` token is broader than a Copilot one, so it goes only to the API of the host it belongs to.

The limits come from `GET /copilot_internal/user`, which GitHub's own clients call. It isn't documented, but the Copilot SDK's types describe it, and VS Code's `parseQuotas` is the reference for reading it:

- Each of `premium_interactions`, `chat` and `completions` becomes a monthly Limit Window if it is finite. `-1` and `unlimited` have none, and neither does a zero entitlement (Free's premium requests).
- `has_quota` is ignored, as it is always false under token billing.
- A seat billed by tokens on an org with no budget per user is unlimited and has only `credits_used`. There is no denominator, so it shows as a count beside no window. On a metered plan that field reads 0 whatever was used, so it is not shown there.

## Considered options

- **Running `copilot` for `account.getQuota`**, a supported SDK call that keeps tokens out of Tinybar, like Gemini's `agy`. But it leaves out everyone without the CLI, the binary is 180 MB to start every 5 minutes, and in 1.0.105 its `resetDate` is the snapshot's timestamp rather than the Reset.
- **A device-flow sign-in**, as CodexBar has: the most reliable, and it means storing a token, against ADR 0001.
- **Decrypting VS Code's login**: another app's private store, and a Keychain prompt for its key.
- **Budgets from `github.com/settings/billing`**, which CodexBar reads with browser cookies: a second source for few users. Add it if credit users ask.

## Token history

Left out, so Copilot has no Usage or Plan Value. Most Copilot use happens in editors, which log nothing Tinybar could read. The CLI's per-request `assistant.usage` event is documented as not saved to disk, leaving only `session.shutdown`'s totals, per session and lost in a crash. A number that misses most use reads as a fact, which is worse than none.

## How it was tested, with no plan

The owner's Copilot subscription has ended, so `Scripts/verify-copilot.py` runs the real Copilot CLI against a local mock with a CA of its own, plus the real `gh`. Copilot's client and Tinybar read the same responses and must agree, which keeps the mock honest. The same script compares them on the real account, whose real answer is `subscription_ended`. That found what fixtures wouldn't have:

- CLI 1.x renamed `last_logged_in_user` to `lastLoggedInUser`, and starts `config.json` with `//` comments.
- `copilot_internal/user` accepts a `gh` token with no Copilot scope, and no editor headers.
- `subscription_ended` comes as a normal 200 with no quotas.

Review added one more that no fixture would show. A newer `gh` renews an expiring token when asked for it, which would break ADR 0001, so Tinybar passes `--no-refresh` where `gh`'s help lists it, and asks for no token if it can't tell. `gh`'s `--user` also minds the case, which GitHub doesn't, so the name is passed as `gh` spells it. The script covers both with the newest `gh` and whichever is installed.

## Consequences

- **Never checked against a real active plan.** The shapes come from the SDK's types, VS Code's parser, and live responses CodexBar's users posted (#690, #1258, #2593), and the real CLI accepted them. The first person with a plan should run `swift run tinybar-cli limits --provider=copilot`. A GitHub account can get Copilot Free at no cost, which would test this for real.
- **The Keychain path has never run.** Reading the owner's item would show a prompt, so it is covered only with a stand-in. That the prompt appears comes from reading the item's access list, and the account format from CLI 0.0.419's item, as 1.0.105 won't store one in a sandbox. Choosing "Always Allow" lets anything that runs `security` read this item, while choosing "Allow" asks again at every poll, since tokens aren't kept between fetches (SECURITY.md). A refusal holds for that account until the next launch.
- **Two formats are second-hand.** Editor plugins' `apps.json` comes from third-party docs, not a real plugin's file. 1.x's plaintext key `copilotTokens` is inferred from its other renames, and read beside the older `copilot_tokens`.
- What the endpoint answers an account that never had Copilot is unknown. Tinybar treats no quotas, and a 404, as having no plan.
- Running `gh` can make it migrate a config from before its multi-account change (2.40) on the spot, on versions that still do this at startup. Nothing is renewed, and `gh` would do the same on its next run. Guarding against it would mean knowing `gh`'s internal config version, so ADR 0001 has this one exception, as the Copilot CLI's own `gh` fallback has.
- `gh`'s rate limit is shared with everything else using that user's token. A 403 about rate limits waits rather than saying the login expired.
- A login only goes to `github.com`, `*.ghe.com` and this Mac. GitHub Enterprise Server isn't supported, which the Copilot CLI doesn't support either.
- One Account for now, the CLI's current user, even though its file can list several.
- No Limit Alerts: monthly windows are neither 5-hour nor weekly, like Cursor's billing cycle.
