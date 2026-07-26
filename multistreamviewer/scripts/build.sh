#!/bin/zsh
# Build release binary, assemble MultiStreamViewer.app, codesign, install to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/MultiStreamViewer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/msv "$APP/Contents/MacOS/msv"
cp scripts/Info.plist "$APP/Contents/Info.plist"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"

mkdir -p ~/Applications
ditto "$APP" ~/Applications/MultiStreamViewer.app
echo "Installed ~/Applications/MultiStreamViewer.app (signed: ${IDENTITY:-ad-hoc})"
