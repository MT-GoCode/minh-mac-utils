#!/bin/zsh
# Remove MultiStreamViewer completely.
# Run:  sudo ./uninstall.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./uninstall.sh"; exit 1; }
USER_NAME="${SUDO_USER:-$(stat -f%Su /dev/console)}"
USER_HOME="$(eval echo "~$USER_NAME")"

echo "▸ stopping app (SIGTERM restores parked windows before exit)"
pkill -x msv 2>/dev/null && sleep 1 || true

echo "▸ removing bundle + CLI symlink"
rm -rf /Applications/MultiStreamViewer.app "$USER_HOME/Applications/MultiStreamViewer.app"
rm -f "$USER_HOME/.local/bin/msv"

echo "▸ clearing permissions + preferences"
tccutil reset Accessibility com.minh.multistreamviewer 2>/dev/null || true
tccutil reset ScreenCapture com.minh.multistreamviewer 2>/dev/null || true
sudo -u "$USER_NAME" defaults delete com.minh.multistreamviewer 2>/dev/null || true

echo "✓ uninstalled"
