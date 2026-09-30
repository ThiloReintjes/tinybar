# Security Policy

## Reporting a vulnerability

Report privately through GitHub: **Security** tab → **Report a vulnerability**.

Include your macOS version, the Tinybar commit or version, reproduction steps and the impact. Please
don't disclose publicly until it's fixed.

We'll respond as quickly as we can and keep you posted.

## Supported versions

Only the latest `main` until the first release. After that, the current release.

## What Tinybar touches

Tinybar handles credentials it doesn't own, so these are the areas of particular interest:

- **CLI credentials.** Claude Code's OAuth token (`~/.claude/.credentials.json` or the
  `Claude Code-credentials` Keychain item, read through `/usr/bin/security`) and the Codex CLI's
  `~/.codex/auth.json`, and Cursor.app's login in its `state.vscdb` (opened read-only). Gemini
  limits come from the Antigravity CLI itself, so Tinybar never sees a Google token. Tinybar holds tokens
  in memory only, for the duration of a fetch. Anything
  that writes, caches, logs or transmits a token anywhere other than the provider's own API host
  is high severity.
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
  `/usr/bin/security` for the Keychain, and a copy of Tinybar itself for the first history import.
  Anything that lets an attacker influence those arguments or the executable path is in scope.
- **Local data.** `~/Library/Application Support/Tinybar/usage.sqlite` stores daily token totals, file
  paths of the logs it read, project folder paths and Claude message IDs. No prompts, no responses,
  no tokens. Anything that puts more than that on disk is a bug.

## Out of scope

- Unsigned or ad-hoc signed development builds.
- Anything that already requires code execution as your user or admin rights on the machine. Such
  an attacker can read the same files Tinybar reads.
- Providers changing or rate-limiting their undocumented endpoints.
