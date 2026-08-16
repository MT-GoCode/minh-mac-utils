#!/bin/zsh
# Build release binary, assemble + codesign build/stayup.app. Does NOT install anywhere —
# `sudo ../install.sh` is the only path that deploys, and it deploys exactly one copy
# (root-owned /Applications), which is what demonlock's spare check wants.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/stayup.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/stayup "$APP/Contents/MacOS/stayup"
cp scripts/Info.plist "$APP/Contents/Info.plist"

IDENTITY=$(bash ../signing-ladder.sh 2>/dev/null || echo "-")
codesign --force --sign "${IDENTITY:--}" "$APP"

echo "built + signed $APP (identity: ${IDENTITY:--})"
echo "deploy with:  sudo ./install.sh"
