#!/bin/bash
# Build + sign the settingslock binary AS THE NORMAL USER (signing needs your
# login keychain). Hardened runtime (-o runtime) blocks code injection into the
# watcher. Run this before install.sh (install.sh calls it for you).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$(id -u)" -eq 0 ]; then echo "Run build.sh as your normal user, not sudo."; exit 1; fi

echo ">> Building release binary..."
swift build -c release --package-path "$REPO_DIR"
BIN="$REPO_DIR/.build/release/settingslock"
[ -f "$BIN" ] || { echo "build failed: no $BIN" >&2; exit 1; }

# Pick the signing identity — Developer ID → stable self-signed → ad-hoc (shared picker;
# it prints the choice to stderr). See ../sign-identity.sh.
SIGN_SH="$REPO_DIR/../sign-identity.sh"
if [ -f "$SIGN_SH" ]; then ID="$(bash "$SIGN_SH")"; else ID="${CODESIGN_IDENTITY:--}"; fi
[ -z "${ID:-}" ] && ID="-"
echo ">> codesign with: $ID (hardened runtime)"
SIGN=(--force --options runtime --sign "$ID")
[ "$ID" != "-" ] && SIGN+=(--timestamp)
codesign "${SIGN[@]}" "$BIN"

codesign --verify --strict "$BIN" || { echo "signature failed to verify" >&2; exit 1; }
# Keep a prebuilt copy so it can be installed without rebuilding (e.g. publish the
# Developer-ID-signed binary as a GitHub release — see the root README).
mkdir -p "$REPO_DIR/dist"; cp "$BIN" "$REPO_DIR/dist/settingslock"
echo ">> Done. Deploy with: ./install.sh   (or sudo ./install/install.sh)"
