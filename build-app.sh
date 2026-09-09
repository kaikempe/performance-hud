#!/bin/bash
# Builds PerformanceHUD.app: a release binary wrapped in a proper .app bundle,
# ad-hoc signed so it runs locally with no Apple Developer account.
set -euo pipefail

cd "$(dirname "$0")"

APP="PerformanceHUD.app"
BIN="PerformanceHUD"

echo "Building release binary..."
swift build -c release

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
