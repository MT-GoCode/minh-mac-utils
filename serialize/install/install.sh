#!/bin/bash
# Install Serialize ROOT-OWNED into /Applications (like demonlock), so the bundle can't be modified
# or swapped without sudo — which is what lets demonlock safely whitelist it from its lockout kill.
# Build runs as you (login keychain for signing); deploy runs as root.  Run:  sudo ./install/install.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./install/install.sh"; exit 1; }
: "${SUDO_USER:?must be run via sudo (need SUDO_USER for the build keychain)}"
USER_NAME="$SUDO_USER"
USER_UID="$(id -u "$USER_NAME")"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="Serialize.app"
DEST="/Applications/$APP"
cd "$HERE"

# Build fresh as the user if a Developer ID cert + toolchain are present; else deploy the prebuilt,
# already-signed dist/ bundle (don't ad-hoc-resign over it). Mirrors demonlock's signing ladder.
HAVE_DEVID="$(sudo -u "$USER_NAME" security find-identity -p codesigning -v 2>/dev/null \
              | grep -c 'Developer ID Application' || true)"
if [ -d "$HERE/dist/$APP" ] && [ "${HAVE_DEVID:-0}" -eq 0 ]; then
    echo "▸ no Developer ID cert — deploying prebuilt dist/$APP (no re-sign)"
    SRC="$HERE/dist/$APP"
elif xcode-select -p >/dev/null 2>&1 && [ -f "$HERE/Package.swift" ]; then
    echo "▸ building + signing as $USER_NAME"
    sudo -u "$USER_NAME" bash install/build.sh
    SRC="$HERE/$APP"
elif [ -d "$HERE/dist/$APP" ]; then
    echo "▸ deploying prebuilt dist/$APP"
    SRC="$HERE/dist/$APP"
else
    echo "✗ no Swift toolchain and no prebuilt dist/$APP" >&2; exit 1
fi
[ -d "$SRC" ] || { echo "✗ no app bundle to deploy"; exit 1; }

echo "▸ stopping any running Serialize"
sudo -u "$USER_NAME" osascript -e 'tell application "Serialize" to quit' >/dev/null 2>&1 || true
pkill -x serialize 2>/dev/null || true

echo "▸ deploying ROOT-OWNED to $DEST"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
chown -R root:wheel "$DEST"        # root-owned ⇒ unmodifiable without sudo (the whole point)
chmod -R go-w "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
/usr/bin/mdimport "$DEST" >/dev/null 2>&1 || true   # nudge Spotlight

# Optional per-user login auto-start (still a gui LaunchAgent — opens the root-owned app). --login
if [ "${1:-}" = "--login" ]; then
    LA="/Users/$USER_NAME/Library/LaunchAgents"
    sudo -u "$USER_NAME" mkdir -p "$LA"
    sed "s#__APP__#$DEST#g" install/com.serialize.login.plist > "$LA/com.serialize.login.plist"
    chown "$USER_NAME" "$LA/com.serialize.login.plist"
    sudo -u "$USER_NAME" launchctl bootout "gui/$USER_UID/com.serialize.login" 2>/dev/null || true
    sudo -u "$USER_NAME" launchctl bootstrap "gui/$USER_UID" "$LA/com.serialize.login.plist" 2>/dev/null || true
    echo "▸ login auto-start enabled"
fi

echo "▸ launching"
sudo -u "$USER_NAME" open "$DEST"

echo
echo "✓ installed $DEST  (root:wheel — demonlock can now safely spare it)"
echo "  • menu-bar icon (top right) → Modify Text / Settings / Hide / Quit"
echo "  • Spotlight: search \"Serialize\""
echo "  • bar modes prompt once for Accessibility (System Settings ▸ Privacy ▸ Accessibility)"
