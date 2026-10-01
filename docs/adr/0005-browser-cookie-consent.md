# Browser cookies are opt-in, per Provider

Reading a browser's cookies can trigger a macOS Keychain prompt for that browser's "Safe Storage" key, and reaches further than reading a CLI's own login. So the cookie fallback for Claude and Codex is off by default and enabled per Provider in Settings. Tinybar only reads cookies for that Provider's own domain and sends them only to that domain.

Cursor is the exception: turning Cursor on is the consent. Many Cursor users have no Cursor.app login on the Mac, so a separate toggle would leave the Provider broken for them. Cursor is only enabled automatically when Cursor.app holds a login, so the cookie is never read without the user choosing Cursor or already using the app.

Safari is not supported because reading its cookies needs Full Disk Access.
