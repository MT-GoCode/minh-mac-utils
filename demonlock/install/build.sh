#!/bin/bash
# Build + bundle + sign demonlock as Demonlock.app.
# Run as your normal user (needs the login keychain for the Developer ID cert). No sudo.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
APP="Demonlock.app"

# Pick the signing identity — Developer ID → stable self-signed → ad-hoc (shared picker;
# it prints the choice to stderr). See ../signing-ladder.sh.
SIGN_SH="$HERE/../signing-ladder.sh"
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

# Refresh the committed prebuilt (dist/) ONLY when explicitly asked with --refresh-dist. install.sh
# deploys $HERE/Demonlock.app directly, so a normal build must NOT write the git-tracked dist/ — else
# every install re-signs a fresh binary into it, dirtying the tree and colliding on the next `git pull`.
# The prebuilt exists purely for installing on a Mac with no Swift toolchain; refresh it deliberately.
if [ "${1:-}" = "--refresh-dist" ]; then
    mkdir -p "$HERE/dist"
    rm -rf "$HERE/dist/$APP"
    cp -R "$APP" "$HERE/dist/$APP"
    echo "✓ refreshed committed prebuilt dist/$APP"
fi

echo
echo "✓ built $HERE/$APP  (signed: $ID)"
echo "  install with:  sudo ./install/install.sh"
