#!/bin/bash
# Install Foreman Uplink: build+sign as your user (sign-identity ladder), deploy
# root-owned to /Applications (so demonlock's spare survives on identifier alone),
# migrate away any old user-level install, relaunch.
# Run:  sudo ./install.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./install.sh"; exit 1; }
: "${SUDO_USER:?must be run via sudo (need SUDO_USER for the build keychain)}"
USER_NAME="$SUDO_USER"
USER_HOME="$(eval echo "~$USER_NAME")"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "▸ building + signing as $USER_NAME"
sudo -u "$USER_NAME" bash "$HERE/build.sh"

echo "▸ stopping any running instance"
sudo -u "$USER_NAME" osascript -e 'quit app "ForemanUplink"' >/dev/null 2>&1 || true
sleep 1
pkill -x ForemanUplink 2>/dev/null || true
pkill -f "ssh -N .*foreman-tunnel" 2>/dev/null || true

echo "▸ deploying root-owned to /Applications (removing any old installs)"
rm -rf "$USER_HOME/Applications/ForemanUplink.app" /Applications/ForemanUplink.app
cp -R "$HERE/ForemanUplink.app" /Applications/ForemanUplink.app
chown -R root:wheel /Applications/ForemanUplink.app
chmod -R go-w /Applications/ForemanUplink.app
xattr -dr com.apple.quarantine /Applications/ForemanUplink.app 2>/dev/null || true

echo "▸ launching as $USER_NAME (re-registers itself as a login item)"
sudo -u "$USER_NAME" open /Applications/ForemanUplink.app

echo "✓ installed. Menu bar should show ❇️ within ~10s."
