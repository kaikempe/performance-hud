#!/bin/bash
# Builds PerformanceHUD.app: a release binary wrapped in a proper .app bundle,
# ad-hoc signed so it runs locally with no Apple Developer account.
set -euo pipefail

cd "$(dirname "$0")"

APP="PerformanceHUD.app"
BIN="PerformanceHUD"

echo "Building release binary..."
# SwiftPM stamps the binary as built against the macOS 14 SDK. On macOS 26+ that
# makes the system draw the pre-Liquid-Glass window chrome (flat rectangular
# panel, no glass), so stamp the real SDK version. The deployment target stays 14.
SDK_VERSION="$(xcrun --show-sdk-version)"
swift build -c release \
    -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION"

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp ".build/release/$BIN" "$APP/Contents/MacOS/$BIN"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "Ad-hoc signing..."
codesign --force --deep --sign - "$APP"

echo "Done → $(pwd)/$APP"
echo "Run it:  open $APP     (look for the stats in your menu bar)"
