# A Provider is a Pool of Accounts, read from logins Tinybar doesn't own

People who run several subscriptions want one view of them, alongside their other Providers (issue #14). So a Provider now has Accounts, and its own Limit Windows are the Pool of theirs: the plain average of what each Account has left. With one Account the Pool is that Account, so nothing changes for most users, and the rings, Overview and menu bar keep reading one set of windows per Provider. Each Account's own figures sit one click deeper, on the Provider page (SPEC §15).

Tinybar learns about Accounts from what already exists on the Mac: the default login, extra login folders (other `CLAUDE_CONFIG_DIR` and `CODEX_HOME` folders, as T3 Code uses) and, if the user turns it on, claude-swap. It has no login of its own, so ADR 0001 holds. It only displays Accounts and never switches between them, although CodexBar does.

claude-swap is opt-in, and read through `cswap list --json` as CodexBar does. That is a versioned public format and Tinybar never touches the tokens behind it. But claude-swap has no cached-only flag, and `cswap list` can renew an idle account's expired login itself, so Tinybar's polling could cause renewals that wouldn't otherwise happen. Tinybar still refreshes nothing, but this stretches the spirit of ADR 0001, so the user chooses it (like ADR 0005). Extra login folders have no such downside, so they are found automatically.

## Considered options

- **A login store in Tinybar**, as CodexBar and T3 Code have for Codex: durable, but it means holding and refreshing tokens, which ADR 0001 rules out.
- **Reading claude-swap's Keychain items or cache file**: both are private formats, the first hands Tinybar every Account's token, and the second only updates when something else polls.
- **The Active Account as the Provider's number**: a used-up idle Account wouldn't matter, but it's wrong for a second Account you are working in, and means little for folders used side by side.
- **The lowest Account as the Provider's number**: one idle Account at 0% would put 0% in the menu bar while plenty is left.
- **A row per Account in the Overview**, as CodexBar offers: three Claude and two Codex Accounts would push Usage off the page. The Overview follows T3 Code instead: one number, and a bar split by Account.

## Consequences

- The Pool's average is unweighted, because claude-swap doesn't report plans, so a Pro and a Max Account count the same. The bar shows each Account for that reason.
- The Pool can look healthy while the Active Account is nearly out. Limit Alerts are per Account, and an Account's window can be pinned to the menu bar, to cover that.
- Pooled windows don't start or end together, so a Pool has no Run-out Time.
- A folder's Keychain item is named with a hash of its path. That naming is undocumented, so a change in Claude Code would hide those Accounts until Tinybar is updated.
- Logs don't say which Account made a request after `cswap switch`, so token history stays per Provider, and Plan Value covers the whole Pool (ADR 0008).
- Cursor, Gemini and OpenCode Go stay at one Account until a way to read a second login turns up.
- `cswap` is an external program whose output can change. An unknown `schemaVersion` keeps the last good reading rather than guessing.
