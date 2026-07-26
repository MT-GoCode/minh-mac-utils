#!/bin/zsh
# Install MultiStreamViewer root-owned to /Applications.
#
# Demonlock spares apps of your own signing team (BULCQM9J2V) only if they're
# root-owned in /Applications -- a user-writable copy fails that check and gets
# killed on lockout. Same deploy pattern as demonlock/wtalk/blockrem.
#
# Run:  sudo ./install.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./install.sh"; exit 1; }
: "${SUDO_USER:?must be run via sudo (need SUDO_USER for the build keychain)}"
USER_NAME="$SUDO_USER"
USER_HOME="$(eval echo "~$USER_NAME")"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "▸ building + signing as $USER_NAME"
sudo -u "$USER_NAME" zsh "$HERE/scripts/build.sh"

echo "▸ stopping any running instance (restores parked windows on the way out)"
pkill -x msv 2>/dev/null && sleep 1 || true

echo "▸ deploying root-owned to /Applications (removing any old installs)"
rm -rf "$USER_HOME/Applications/MultiStreamViewer.app" /Applications/MultiStreamViewer.app
cp -R "$HERE/build/MultiStreamViewer.app" /Applications/MultiStreamViewer.app
chown -R root:wheel /Applications/MultiStreamViewer.app
chmod -R go-w /Applications/MultiStreamViewer.app
xattr -dr com.apple.quarantine /Applications/MultiStreamViewer.app 2>/dev/null || true

echo "▸ exposing CLI as ~/.local/bin/msv"
sudo -u "$USER_NAME" mkdir -p "$USER_HOME/.local/bin"
sudo -u "$USER_NAME" ln -sf /Applications/MultiStreamViewer.app/Contents/MacOS/msv \
    "$USER_HOME/.local/bin/msv"

echo "▸ launching as $USER_NAME"
sudo -u "$USER_NAME" open /Applications/MultiStreamViewer.app

echo "✓ installed. Root-owned /Applications bundle (demonlock spares it)."
echo "  First run: Settings → Permissions → Request Missing → grant → Relaunch App."
echo "  CLI: msv show|hide|toggle|new|switch N|next"
