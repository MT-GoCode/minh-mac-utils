#!/bin/bash
# Uninstall Serialize.  sudo ./install/uninstall.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./install/uninstall.sh"; exit 1; }
USER_NAME="${SUDO_USER:-$(stat -f %Su /dev/console)}"
USER_UID="$(id -u "$USER_NAME")"

echo "▸ stopping + unloading"
sudo -u "$USER_NAME" osascript -e 'tell application "Serialize" to quit' >/dev/null 2>&1 || true
pkill -x serialize 2>/dev/null || true
sudo -u "$USER_NAME" launchctl bootout "gui/$USER_UID/com.serialize.login" 2>/dev/null || true

echo "▸ removing files"
rm -rf /Applications/Serialize.app
rm -rf "/Users/$USER_NAME/Applications/Serialize.app"   # old user-owned install, if any
rm -f "/Users/$USER_NAME/Library/LaunchAgents/com.serialize.login.plist"

echo "✓ uninstalled"
