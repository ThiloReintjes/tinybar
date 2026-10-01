# Theoretical Cost uses current models.dev prices, never a guess

Prices come from models.dev, fetched at most once a day and cached on disk. Cost is computed at display time from stored token counts and today's prices. There is no bundled price table. A model with no price, including any model before the first fetch, shows "—". The only matching beyond the exact model ID is that a dated snapshot (`claude-x-20250101`) uses its base model's price.

A bundled table goes stale silently and ships wrong numbers with every release. Pricing an unknown model "like the closest one" produces a believable but wrong figure. A visible "—" is honest and fixes itself once models.dev lists the model.

## Consequences

- Past days are re-priced when prices change. Theoretical Cost answers "what would this usage cost today", not "what did it cost then". Historical pricing is deferred (SPEC §12).
- models.dev is the only extra network destination, and it is unauthenticated.
