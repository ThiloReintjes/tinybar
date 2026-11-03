# Logins from any folder, added by hand or by the user's agent, and every Copilot user

Accounts (ADR 0010) found extra logins only in `.claude*` and `.codex*` folders in the home folder. Other tools keep logins elsewhere: CodexBar's account manager keeps each Codex login in its own `CODEX_HOME` under `~/Library/Application Support/CodexBar`, and a `CODEX_HOME` can be anywhere a shell file points. Those Accounts were invisible, and nothing said where Tinybar had looked.

So each subscription's page in Settings now lists every login with where it's read from, and says where Tinybar looks. A folder anywhere else is added under Other logins, by hand, with a picker that checks it holds a login, or by the user's coding agent from a prompt Tinybar copies. The agent adds each folder with `defaults write <domain> addedLoginFolders -array-add <path>`. That needs nothing new in Tinybar, works from any agent, and the list is read afresh on every check. The prompt has the agent check only that the files exist, since they hold tokens.

The same applies to every CLI whose login can live in another folder: Claude Code, Codex, Grok (`GROK_HOME`), the Copilot CLI (`COPILOT_HOME`) and OpenCode (`$XDG_DATA_HOME/opencode`). One table in `LoginFolders.swift` holds what differs between them, so the home-folder names, the picker's check, the prompt and the fix for an expired login can't drift apart.

Copilot is different: the Copilot CLI keeps several users in one `config.json`, and `gh` several per host. Those users are Accounts too, with the default login's opt-in rules, so no new Keychain prompt appears unless the user turned Copilot on.

## Considered options

- **Reading CodexBar's managed accounts automatically**: it would have found the account that started this, but it ties Tinybar to another app's private layout. That login had also been expired for weeks: CodexBar wasn't keeping it alive either.
- **Searching the disk for login files**: slow, needs access prompts for protected folders, and turns up backups and test fixtures. The user's agent can search with judgement, and the user sees what it added.
- **A URL scheme or a config file for the agent to write**: `defaults` already does this, and Tinybar keeps its settings in UserDefaults alone (SPEC §11).

## Consequences

- An added folder is trusted like a found one: Tinybar sends its token to the same hosts the default login's goes to, and nowhere else.
- A gh account with no Copilot plan is left out, so a GitHub account used only for other work doesn't drag the Copilot Pool to zero.
- An added OpenCode folder shows limits only. Its token history would need a cursor per database, and a second OpenCode data folder is rare.
- Cursor keeps one login per app and the Antigravity CLI uses one fixed folder, so Cursor and Gemini stay at one Account.
- `auth.json` is Codex's, Grok's and OpenCode's file name. Each CLI's own reading decides whose a folder is, and one folder may count for several.
