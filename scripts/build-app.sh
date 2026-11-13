#!/bin/bash
# Builds NoSleep.app (ad-hoc signed).
# Usage: scripts/build-app.sh [--install]   (--install copies it to /Applications and launches it)
# Env:   ARCHS="arm64 x86_64" (default: universal)  MIN_MACOS=14.0  APP_OUT=build/NoSleep.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP=${APP_OUT:-build/NoSleep.app}
MIN_MACOS=${MIN_MACOS:-14.0}
export NOSLEEP_MIN_MACOS=$MIN_MACOS
CONTENTS=$APP/Contents
read -r -a ARCHS <<< "${ARCHS:-arm64 x86_64}"

echo "▸ Running self-tests"
# They run on this Mac, so build them for this Mac's macOS, not the release's minimum (a macOS 26 build
# can't run on a macOS 14 build host).
SELFTEST=(env -u NOSLEEP_MIN_MACOS swift build -c release --scratch-path .build/selftest)
"${SELFTEST[@]}" --product nosleep-selftest >"${TMPDIR:-/tmp}/nosleep-selftest-build.log" 2>&1 || { grep -E "error" "${TMPDIR:-/tmp}/nosleep-selftest-build.log"; exit 1; }
"$("${SELFTEST[@]}" --show-bin-path 2>/dev/null)/nosleep-selftest"

LOG=$(mktemp)
BINS=()
for arch in "${ARCHS[@]}"; do
  echo "▸ Building $arch"
  TRIPLE="$arch-apple-macosx$MIN_MACOS"
  if swift build -c release --scratch-path ".build/$arch-$MIN_MACOS" --triple "$TRIPLE" --product NoSleepApp >"$LOG" 2>&1 \
     && swift build -c release --scratch-path ".build/$arch-$MIN_MACOS" --triple "$TRIPLE" --product nosleep >>"$LOG" 2>&1; then
    BINS+=("$(swift build -c release --scratch-path ".build/$arch-$MIN_MACOS" --triple "$TRIPLE" --show-bin-path 2>/dev/null)")
  else
    grep -E "error:" "$LOG" | grep -v -E "xcrun|PlatformPath" | head -20 || tail -20 "$LOG"
    echo "  ✗ $arch build failed"
    exit 1
  fi
done
[ ${#BINS[@]} -gt 0 ] || { echo "Build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources"
lipo -create $(printf '%s/NoSleepApp ' "${BINS[@]}") -output "$CONTENTS/MacOS/NoSleep"
lipo -create $(printf '%s/nosleep ' "${BINS[@]}") -output "$CONTENTS/Helpers/nosleep"
cp Resources/Info.plist "$CONTENTS/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$MIN_MACOS" "$CONTENTS/Info.plist"

echo "▸ Rendering icon"
ICONSET=$(mktemp -d)/AppIcon.iconset
swift scripts/make-icon.swift "$ICONSET" 2>/dev/null
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

# Signing, best first:
#  1. DEVELOPER_ID="Developer ID Application: Name (TEAMID)": distributable, required for notarization.
#  2. Stable local self-signed identity (scripts/signing-identity.sh) so macOS keeps recognising the
#     app across updates (Login Items!).
#  3. Ad-hoc.
EXTRA=()
if [ -n "${DEVELOPER_ID:-}" ]; then
  IDENTITY=$DEVELOPER_ID
  EXTRA=(--timestamp)
  echo "▸ Signing ($DEVELOPER_ID)"
elif SIGNING=$(scripts/signing-identity.sh 2>/dev/null); then
  IDENTITY=$(echo "$SIGNING" | head -1)
  echo "▸ Signing (NoSleep Local Signing)"
else
  IDENTITY=-
  echo "▸ Signing (ad-hoc)"
fi
codesign --force --sign "$IDENTITY" --options runtime "${EXTRA[@]+"${EXTRA[@]}"}" \
  --identifier com.tomaspinausig.nosleep.cli "$CONTENTS/Helpers/nosleep"
codesign --force --sign "$IDENTITY" --options runtime "${EXTRA[@]+"${EXTRA[@]}"}" "$APP"
codesign --verify --strict "$APP"

echo "✓ $APP ($(lipo -archs "$CONTENTS/MacOS/NoSleep"), macOS $MIN_MACOS+)"

if [ "${1:-}" = "--install" ]; then
  osascript -e 'tell application id "com.tomaspinausig.nosleep" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf /Applications/NoSleep.app
  cp -R "$APP" /Applications/
  open /Applications/NoSleep.app
  echo "✓ Installed to /Applications/NoSleep.app"
fi
