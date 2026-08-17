#!/bin/bash
# Remove forcecalls.  sudo ./uninstall.sh [--purge]
# Without --purge the schedule and credentials are left in place, so a reinstall picks up where you
# left off. --purge deletes them — that is the only instant way to drop a forced call, and it needs
# your password on purpose.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./uninstall.sh"; exit 1; }
SUPPORT="/Library/Application Support/Forcecalls"

launchctl bootout system/com.forcecalls.daemon 2>/dev/null || true
[ -n "${SUDO_USER:-}" ] && launchctl bootout "gui/$(id -u "$SUDO_USER")/com.forcecalls.agent" 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.forcecalls.daemon.plist /Library/LaunchAgents/com.forcecalls.agent.plist
rm -f /usr/local/bin/forcecalls /usr/local/libexec/forcecalls
rm -rf /Applications/Forcecalls.app
echo "  ✓ daemon, agent, app + binaries removed"

if [ "${1:-}" = "--purge" ]; then
    rm -rf "$SUPPORT"
    echo "  ✓ purged $SUPPORT (schedule + credentials gone)"
else
    echo "  · kept $SUPPORT — reinstall to resume, or re-run with --purge to wipe it"
fi
