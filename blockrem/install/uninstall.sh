#!/bin/bash
# Uninstall Blockrem.  sudo ./install/uninstall.sh [--purge]
# --purge also removes the support dir (the schedule + settings).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./install/uninstall.sh"; exit 1; }
USER_NAME="${SUDO_USER:-$(stat -f %Su /dev/console)}"
USER_UID="$(id -u "$USER_NAME")"

echo "▸ unloading services"
launchctl bootout "gui/$USER_UID/com.blockrem.agent" 2>/dev/null || true
launchctl bootout system/com.blockrem.enforcerd 2>/dev/null || true

echo "▸ removing files"
rm -f /Library/LaunchDaemons/com.blockrem.enforcerd.plist
rm -f /Library/LaunchAgents/com.blockrem.agent.plist
rm -rf /Applications/Blockrem.app
rm -f /usr/local/bin/blockrem

if [ "${1:-}" = "--purge" ]; then
    rm -rf "/Library/Application Support/Blockrem"
    echo "  purged support dir (schedule/settings)"
fi

echo "✓ uninstalled"
