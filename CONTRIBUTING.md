# Contributing to Tinybar

Check existing [issues](https://github.com/ThiloReintjes/tinybar/issues) and
[pull requests](https://github.com/ThiloReintjes/tinybar/pulls) first, then open an issue before you
write code. Docs-only fixes are the exception.

> **Take your time. A small, correct change beats a fast one.**

## Non-negotiables

- **Read-only credentials.** Never refresh, write or rewrite a token, a CLI's credential file or a
  browser cookie. Never call an endpoint that changes state (redeeming a banked reset, sending a
  prompt). A stale card is the intended behaviour, not a bug to fix with a refresh flow. Changing
  this needs a new ADR, see [ADR 0001](docs/adr/0001-read-only-credentials.md).
- **Idle is free.** 0% CPU while the popover is closed. No timer faster than the 5-minute poll, no
  animation loops, no polling of the file system (FSEvents only).
- **Memory.** Under 50 MB resident at steady state; today it's ~20 MB footprint. Heavy one-off work
  (like the first history import) runs in a child process.
- **Incremental only.** Log ingestion reads appended bytes. Nothing rescans the history on a timer.
- **No WebViews, no embedded JS engines, no long-lived child processes.** A new dependency has to
  justify itself against the budgets above.
- **Accurate numbers.** A change to log parsing must be checked against an independent count of real
  logs (a short Python script is fine) and the result reported in the PR.

## Setup

- macOS 14+, Swift 6 toolchain (Xcode 16 or newer).
- `swift build`, then `.build/debug/Tinybar` runs the app unbundled (no notifications or launch at
  login). `./Scripts/build-app.sh && open build/Tinybar.app` for the real thing.
- Layout: `Sources/TinybarCore` holds providers, parsing, storage and pricing, with no UI;
  `Sources/Tinybar` is the menu bar app; `Sources/tinybar-cli` is a developer tool.
- Read [SPEC.md](SPEC.md) and [CONTEXT.md](CONTEXT.md). Use the glossary's terms in code and PRs:
  Provider, Limit Window, Banked Reset, Usage Record, Theoretical Cost.

## Before submitting

- A linked issue. Put `Closes #<number>` in the PR description.
- `swift test` passes and the app builds with `./Scripts/build-app.sh`. Parsing and mapping changes
  come with test cases.
- Performance measured, numbers in the PR. After a few minutes idle:

  ```sh
  pid=$(pgrep -x Tinybar); ps -o %cpu=,rss=,time= -p $pid; footprint $pid | grep Footprint
  ```

- You used the app with your change, including after a restart.
- Rebased on `main`, squashed into logical commits with imperative messages
  (`Add Gemini provider`).
- Anything in `SPEC.md`, `CONTEXT.md` or `README.md` your change makes wrong is fixed.
- Read your own diff top to bottom before opening the PR.

## Pull requests

- Visual change → before and after screenshots, light and dark. `.build/debug/Tinybar --snapshot
  out.png --redact-projects` renders both without your project names.
- Non-visual → say what you tested and how.
- Flag anything surprising, and any trade-off you made on purpose.
- Behaviour you didn't mean to change, didn't change. Say so if it did.

## Adding a provider

Open an issue first and say which plan you're on. For the PR:

- Take the data from where the provider's own CLI or app already keeps it, and call the endpoints
  that client itself calls. Show the request headers and response shape in the PR.
- Implement `UsageProvider` in `Sources/TinybarCore/<Provider>/`, mapping to `LimitWindow`s with
  `id`s that stay stable across fetches (pinning and alerts depend on them).
- Map every error to `ProviderError`, so an expired login shows as stale with a hint.
- Test the mapping with a response fixture. Never commit real tokens, emails or account IDs.

## Bugs

macOS version, Tinybar commit, steps, expected vs actual. For wrong numbers: the provider, the time
range, and what the official client shows for the same range.

## Security

Not in the issue tracker. See [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). Contributions are licensed under the same terms.
