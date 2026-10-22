#!/bin/bash
# Builds a universal Tinybar.app into build/, ad-hoc signed by default.
#
# For distribution, set SIGN_IDENTITY="Developer ID Application: …". With notary credentials too,
# the app is notarized and stapled: NOTARY_PROFILE (a `xcrun notarytool store-credentials` profile),
# or an App Store Connect API key as NOTARY_KEY (path to the .p8), NOTARY_KEY_ID and NOTARY_ISSUER.
# `--zip` also writes build/Tinybar-<version>.zip, the release asset.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Tinybar --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/Tinybar"

APP="build/Tinybar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tinybar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --options runtime --timestamp=none --sign - "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--zip" ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
    ZIP="build/Tinybar-$VERSION.zip"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        NOTARY=(--keychain-profile "$NOTARY_PROFILE")
    elif [[ -n "${NOTARY_KEY:-}" ]]; then
        NOTARY=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
    fi
    if [[ -n "${SIGN_IDENTITY:-}" && -n "${NOTARY+x}" ]]; then
        ditto -c -k --keepParent "$APP" "$ZIP"
        xcrun notarytool submit "$ZIP" "${NOTARY[@]}" --wait
        xcrun stapler staple "$APP"
    fi
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Built $ZIP"
fi
