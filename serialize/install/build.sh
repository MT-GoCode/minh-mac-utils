#!/bin/bash
# Build + bundle + sign serialize as Serialize.app.
# Run as your normal user (needs the login keychain for signing). No sudo.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
APP="Serialize.app"

# Shared signing-identity picker at the repo root: Developer ID → stable self-signed → ad-hoc.
# (Stable self-signed keeps the Accessibility/TCC grant across rebuilds; ad-hoc resets it.)
SIGN_SH="$HERE/../sign-identity.sh"
if [ -f "$SIGN_SH" ]; then ID="$(bash "$SIGN_SH")"; else ID="${CODESIGN_IDENTITY:--}"; fi
[ -z "${ID:-}" ] && ID="-"

echo "▸ swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/serialize"
echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/serialize"
cp install/Info.plist "$APP/Contents/Info.plist"

echo "▸ codesign with: $ID"
SIGN=(--force --options runtime --sign "$ID")
[ "$ID" != "-" ] && SIGN+=(--timestamp)
codesign "${SIGN[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# Prebuilt signed copy so the folder can be installed on a Mac with no Swift toolchain.
mkdir -p "$HERE/dist"
rm -rf "$HERE/dist/$APP"
cp -R "$APP" "$HERE/dist/$APP"

echo
echo "✓ built $HERE/$APP  (signed: $ID; copied to dist/)"
echo "  install with:  ./install/install.sh"
