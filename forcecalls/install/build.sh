#!/bin/bash
# Build the CLI/daemon binary and bundle + sign the GUI agent as Forcecalls.app.
# Run as your normal user (signing needs the login keychain). No sudo.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
APP="Forcecalls.app"

SIGN_SH="$HERE/../signing-ladder.sh"
if [ -f "$SIGN_SH" ]; then ID="$(bash "$SIGN_SH")"; else ID="${CODESIGN_IDENTITY:--}"; fi
[ -z "${ID:-}" ] && ID="-"

echo "▸ swift build -c release"
swift build -c release
BINDIR="$(swift build -c release --show-bin-path)"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINDIR/forcecalls-agent" "$APP/Contents/MacOS/forcecalls-agent"
cp install/Info.plist "$APP/Contents/Info.plist"

echo "▸ codesign with: $ID"
SIGN=(--force --options runtime --sign "$ID")
[ "$ID" != "-" ] && SIGN+=(--timestamp)
codesign "${SIGN[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# Keep prebuilt copies so this folder installs on a Mac with no Swift toolchain.
mkdir -p "$HERE/dist"
rm -rf "$HERE/dist/$APP"
cp -R "$APP" "$HERE/dist/$APP"
cp "$BINDIR/forcecalls" "$HERE/dist/forcecalls"

echo
echo "✓ built $HERE/$APP  (signed: $ID; copied to dist/)"
echo "  install with:  sudo ./install.sh"
