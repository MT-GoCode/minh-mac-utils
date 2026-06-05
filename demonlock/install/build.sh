#!/bin/bash
# Build + bundle + sign demonlock as Demonlock.app.
# Run as your normal user (needs the login keychain for the Developer ID cert). No sudo.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
APP="Demonlock.app"

# Pick the signing identity — Developer ID → stable self-signed → ad-hoc (shared picker;
# it prints the choice to stderr). See ../sign-identity.sh.
SIGN_SH="$HERE/../sign-identity.sh"
if [ -f "$SIGN_SH" ]; then ID="$(bash "$SIGN_SH")"; else ID="${CODESIGN_IDENTITY:--}"; fi
[ -z "${ID:-}" ] && ID="-"

echo "▸ swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/demonlock"
echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/demonlock"
cp install/Info.plist "$APP/Contents/Info.plist"

echo "▸ codesign with: $ID"
SIGN=(--force --options runtime --sign "$ID")
[ "$ID" != "-" ] && SIGN+=(--timestamp)
codesign "${SIGN[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# Keep a prebuilt, signed copy so this folder can be installed on a Mac with NO Swift toolchain.
# Developer ID + secure timestamp ⇒ it runs on any Mac and stays valid after the cert expires.
mkdir -p "$HERE/dist"
rm -rf "$HERE/dist/$APP"
cp -R "$APP" "$HERE/dist/$APP"

echo
echo "✓ built $HERE/$APP  (signed: $ID; copied to dist/)"
echo "  install with:  sudo ./install/install.sh"
