#!/bin/bash
# Builds a universal, ad-hoc signed Subar.app into build/.
# Set SIGN_IDENTITY="Developer ID Application: …" to sign for distribution.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Subar --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/Subar"

APP="build/Subar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Subar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
