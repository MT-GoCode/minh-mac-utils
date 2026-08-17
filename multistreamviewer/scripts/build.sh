#!/bin/zsh
# Build release binary, assemble + codesign build/multistreamviewer.app. Does NOT install anywhere —
# `sudo ../install.sh` is the only path that deploys, and it deploys exactly one copy
# (root-owned /Applications). A second user-owned copy in ~/Applications would be a
# weaker-verified duplicate demonlock treats under a stricter rule, so we don't make one.
#
# Signing: ../signing-ladder.sh picks the Developer ID (team BULCQM9J2V) first, which is
# what lets demonlock verify the app even before the root-owned check.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/multistreamviewer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/multistreamviewer "$APP/Contents/MacOS/multistreamviewer"
cp scripts/Info.plist "$APP/Contents/Info.plist"

IDENTITY=$(bash ../signing-ladder.sh 2>/dev/null || echo "-")
codesign --force --sign "${IDENTITY:--}" "$APP"

echo "built + signed $APP (identity: ${IDENTITY:--})"
echo "deploy with:  sudo ./install.sh"
