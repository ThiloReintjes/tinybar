# Updates install through Homebrew

Tinybar asks GitHub for its latest release once a day. When there's a newer one, the popover footer offers it, and a single click installs it through Homebrew, which installed Tinybar in the first place. The tap is pulled and the new zip downloaded while Tinybar keeps running. Then a short script that outlives Tinybar waits for it to quit, runs `brew upgrade --cask thiloreintjes/tinybar/tinybar`, and opens the new version. If Homebrew fails, the old version opens again and says why. Copying the command for Terminal is the fallback. An install that isn't from Homebrew gets the release page instead.

Sparkle was the plan (ADR 0002), but it would be a second updater beside Homebrew. The two would fight over the same app bundle, and Sparkle's signed appcast adds release work for no gain while Homebrew already verifies the zip against the cask's sha256.

Homebrew quarantines each new app, and since 0.6.0 releases are notarized, so Gatekeeper opens them without asking. Before that, releases were ad-hoc signed and the script removed the `com.apple.quarantine` attribute after a successful upgrade, so the user didn't have to approve every update the way they approved the first install.

## Consequences

- GitHub's API is contacted once a day without credentials, on top of models.dev and the status pages.
- If the tap and the release disagree (the cask bump lags the tag), the footer says Homebrew doesn't list the version yet and changes nothing.
