# Updates install through Homebrew, and clear the quarantine flag

Tinybar asks GitHub for its latest release once a day. When there's a newer one, the popover footer offers it, and a single click installs it through Homebrew, which installed Tinybar in the first place. The tap is pulled and the new zip downloaded while Tinybar keeps running. Then a short script that outlives Tinybar waits for it to quit, runs `brew upgrade --cask thiloreintjes/tinybar/tinybar`, and opens the new version. If Homebrew fails, the old version opens again and says why. Copying the command for Terminal is the fallback. An install that isn't from Homebrew gets the release page instead.

Sparkle was the plan (ADR 0002), but it would be a second updater beside Homebrew. The two would fight over the same app bundle, and Sparkle's signed appcast adds release work for no gain while Homebrew already verifies the zip against the cask's sha256.

Releases aren't notarized yet, so Homebrew quarantines each new app and Gatekeeper would ask the user to approve every update the way it did the first install. After a successful upgrade the script removes the `com.apple.quarantine` attribute from the app. The user asked for this update by clicking it, and its integrity comes from the sha256 in the tap, the same trust a Sparkle update without notarization would have. A manual `brew upgrade` still quarantines as usual.

## Consequences

- GitHub's API is contacted once a day without credentials, on top of models.dev and the status pages.
- Clearing the quarantine flag stops once releases are notarized: then the flag passes Gatekeeper on its own and the step can go.
- If the tap and the release disagree (the cask bump lags the tag), the footer says Homebrew doesn't list the version yet and changes nothing.
