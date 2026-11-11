#!/bin/bash
# Packages an Apple Silicon DMG.
# Usage: scripts/package-dmg.sh <min macOS> <label>     e.g. scripts/package-dmg.sh 14.0 sonoma
set -euo pipefail
cd "$(dirname "$0")/.."

MIN_MACOS=${1:?min macOS, e.g. 14.0}
LABEL=${2:?label, e.g. sonoma}
VERSION=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
STAGE=build/dmg-$LABEL
DMG=build/NoSleep-$VERSION-$LABEL-apple-silicon.dmg

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ARCHS=arm64 MIN_MACOS=$MIN_MACOS APP_OUT="$STAGE/NoSleep.app" scripts/build-app.sh
ln -s /Applications "$STAGE/Applications"

echo "▸ Creating $DMG"
hdiutil create -volname "No Sleep $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
