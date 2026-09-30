#!/bin/bash
# Builds a universal, ad-hoc signed Tinybar.app into build/.
# Set SIGN_IDENTITY="Developer ID Application: …" to sign for distribution.
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

codesign --force --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
