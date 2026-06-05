#!/bin/bash
# Uninstall Demonlock.  sudo ./install/uninstall.sh [--purge]
# --purge also removes the support dir (zones, policy, settings).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./install/uninstall.sh"; exit 1; }
USER_NAME="${SUDO_USER:-$(stat -f %Su /dev/console)}"
USER_UID="$(id -u "$USER_NAME")"

echo "▸ unloading services"
launchctl bootout "gui/$USER_UID/com.demonlock.agent" 2>/dev/null || true
launchctl bootout system/com.demonlock.enforcerd 2>/dev/null || true

echo "▸ removing files"
rm -f /Library/LaunchDaemons/com.demonlock.enforcerd.plist
rm -f /Library/LaunchAgents/com.demonlock.agent.plist
rm -rf /Applications/Demonlock.app
rm -f /usr/local/bin/demonlock
rm -f /etc/sudoers.d/demonlock
rm -f /var/run/demonlock.sock

if [ "${1:-}" = "--purge" ]; then
    rm -rf "/Library/Application Support/Demonlock"
    echo "  purged support dir (zones/policy/settings)"
fi

echo "✓ uninstalled"
