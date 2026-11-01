# Security Policy

## Reporting a vulnerability

Report privately through GitHub: **Security** tab → **Report a vulnerability**.

Include your macOS version, the Tinybar version, reproduction steps and the impact. Please
don't disclose publicly until it's fixed.

We'll respond as quickly as we can and keep you posted.

## Supported versions

The latest release only. Update (`brew upgrade --cask thiloreintjes/tinybar/tinybar`) before reporting.

## What Tinybar touches

Tinybar handles credentials it doesn't own, so these are the areas of particular interest:

- **CLI credentials.** Claude Code's OAuth token (`~/.claude/.credentials.json` or the
  `Claude Code-credentials` Keychain item, read through `/usr/bin/security`) and the Codex CLI's
  `~/.codex/auth.json`, and Cursor.app's login in its `state.vscdb` (opened read-only). Gemini
  limits come from the Antigravity CLI itself, so Tinybar never sees a Google token. Tinybar holds tokens
  in memory only, for the duration of a fetch. Anything
  that writes, caches, logs or transmits a token anywhere other than the provider's own API host
  is high severity.
- **Extra logins.** Other `~/.claude*` and `~/.codex*` folders are read the same way: their
  `.credentials.json` or the `Claude Code-credentials-<hash>` Keychain item, and `auth.json`. The emails
  beside those logins are shown in the popover; pins, alert state and limit readings store a hash of
  them. The log paths in the local database can name one, since claude-swap names its `cswap run`
  profiles after the account.
- **Browser cookies.** Off by default. When enabled, Tinybar reads session cookies for `claude.ai`,
  `chatgpt.com` and (with the Cursor provider on) `cursor.com` only, decrypting Chromium cookies with the browser's "Safe Storage" Keychain key
  (cached in memory for the app's lifetime). Reading cookies for any other domain, or sending
  cookies to any host other than the one they belong to, is high severity.
- **Network.** Tinybar talks to exactly four places: `api.anthropic.com` / `claude.ai`,
  `chatgpt.com`, `cursor.com`, and `models.dev` (unauthenticated). The `agy` child process talks to
  Google on its own. Any other destination, or any request that
  changes account state, is a bug.
- **Child processes.** `codex -s read-only -a never app-server` for the Codex fallback,
  `agy -p /usage --output-format json` (in an empty temporary directory) for Gemini,
  `cswap list --json` for claude-swap's accounts (only if turned on in Settings; it holds its own
  tokens and may renew idle logins itself),
  `/usr/bin/security` for the Keychain, and a copy of Tinybar itself for the first history import.
  Anything that lets an attacker influence those arguments or the executable path is in scope.
- **Local data.** `~/Library/Application Support/Tinybar/usage.sqlite` stores daily token totals, file
  paths of the logs it read, project folder paths, Claude message IDs and daily Activity counters.
  For de-duplication it also keeps, for up to 90 days, the ids of Claude tool calls, prompts, edits
  and compactions, tool names (MCP tools only as "MCP") and the timestamps of each response. No
  prompts, no responses, no commands, file contents or diffs, no tokens. Anything that puts more
  than that on disk is a bug.

## Out of scope

- Unsigned or ad-hoc signed development builds.
- Anything that already requires code execution as your user or admin rights on the machine. Such
  an attacker can read the same files Tinybar reads.
- Providers changing or rate-limiting their undocumented endpoints.
