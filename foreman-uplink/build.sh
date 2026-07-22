#!/usr/bin/env bash
# Build + sign ForemanUplink.app into this directory (deployment is install.sh's job).
# Signing identity comes from the shared ladder: ../sign-identity.sh
#   $CODESIGN_IDENTITY → Developer ID → "Mac Utils Local Signing" self-signed → ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"

APP="$PWD/ForemanUplink.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/ForemanUplink" main.swift \
    -framework AppKit -framework ServiceManagement
cp Info.plist "$APP/Contents/Info.plist"

IDENTITY="$(../sign-identity.sh)"
codesign --force -s "$IDENTITY" "$APP"
echo "built + signed: $APP"
