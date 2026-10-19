# Plain SwiftPM, no Xcode project, no dependencies

Tinybar is a Swift package with no Xcode project. `Scripts/build-app.sh` assembles `Tinybar.app` from the release binary, `Resources/Info.plist` and the icon, which `Scripts/make-icon.swift` draws because there is no asset catalog. The repo stays plain text that diffs and reviews well, and it builds with `swift build` locally and in CI.

There are no third-party dependencies. The system already provides what Tinybar needs: SQLite, Swift Charts, `URLSession`, `SMAppService`, and CommonCrypto for browser cookies. Every dependency costs binary size, memory and supply-chain trust against the budget in SPEC §2. Updates go through Homebrew, which installed Tinybar, so Sparkle is no longer planned (ADR 0007).

## Consequences

- Anything Xcode would generate, such as signing, the asset catalog or the bundle layout, lives in `Scripts/`.
- Proposals to add a package have to justify themselves against §2. "It saves some code" is not enough.
