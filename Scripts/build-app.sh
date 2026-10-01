#!/bin/bash
# Builds a universal Tinybar.app into build/, ad-hoc signed by default.
#
# For distribution, set SIGN_IDENTITY="Developer ID Application: …". With NOTARY_PROFILE set too
# (a `xcrun notarytool store-credentials` profile), the app is notarized and stapled.
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
    if [[ -n "${SIGN_IDENTITY:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
        ditto -c -k --keepParent "$APP" "$ZIP"
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
    fi
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Built $ZIP"
fi
