# Measure what a plan buys from the user's own limits, and compare models on a copied benchmark

People ask how much API use a subscription includes, and providers don't say. Tinybar sees both sides on one Mac: how much of a Limit Window went, and what the logged tokens would cost. Dividing one by the other gives a dollar figure for this account (SPEC §14), with no guess about the provider's limits and nothing sent anywhere.

Dollars don't say which model to use, so the page also shows each model's Intelligence Index score, cost and time per task from Artificial Analysis. Those come from one small table in the code, with the date it was copied and a link. Tinybar can't fetch them. The site's Terms of Use forbid automated requests and scraping, and its free API needs a key, asks not to be used from client code, and doesn't document these per-task fields.

An earlier version counted the user's own tasks and agent hours instead. A cost per task from one's own prompts proved hard to read, and it wasn't comparable between models.

These figures sit on a Plans page in the Stats window. They answer an occasional question, and on each Provider page they crowded the limits and usage people open the popover for.

A window's value is computed at display time from hourly token counters, so it follows current prices (ADR 0004) and needs only one new table of readings, not finer token history (ADR 0003).

Plan prices are bundled too: no feed lists them, they change rarely, and a plan that isn't listed shows no per-dollar figure. Codex's `pro` is assumed to be the $200 tier, since the logs don't tell it from the $500 one.

## Consequences

- **Before any public release, get Artificial Analysis's permission.** Its terms say no part of the site may be copied, republished or distributed except as they state, and its API docs direct redistribution requests to its team. Attribution alone doesn't settle this. If permission doesn't come, delete `ModelBenchmark`, the model list and the chart; the dollar figures don't depend on them.
- The table goes stale, which ADR 0004 avoids for prices. The page shows its date, and a new model doesn't appear until someone copies it in.
- Tasks a week assume the limit counts every model at its API price, which providers don't confirm. Adam Holter's published estimates suggest Claude Fable 5.1 takes far more of a limit than its price implies, so its row may be too high.
- The dollars are a floor. Use outside the logged CLIs (claude.ai, ChatGPT) takes up the limit without showing in the logs, and Banked Resets aren't counted.
- History starts with this version. Codex logs carry `rate_limits` on each `token_count` line and could provide past windows, but only for logs not yet compressed; left for later.
