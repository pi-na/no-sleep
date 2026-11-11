#!/bin/bash
# Packages an Apple Silicon DMG.
# Usage: scripts/package-dmg.sh <min macOS> <label>     e.g. scripts/package-dmg.sh 14.0 sonoma
# Set DEVELOPER_ID (+ NOTARY_PROFILE) to produce a notarized DMG — see below.
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

# Notarization (needs an Apple Developer Program membership):
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE=<name>   created once with:
#     xcrun notarytool store-credentials <name> --apple-id you@example.com --team-id TEAMID
#                                               --password <app-specific password>
if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "▸ Notarizing (this takes a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
    echo "✓ Notarized and stapled"
  else
    echo "  (signed with Developer ID; set NOTARY_PROFILE to notarize)"
  fi
fi
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
