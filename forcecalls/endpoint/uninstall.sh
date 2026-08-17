#!/bin/bash
# Remove the forcecalls endpoint.  sudo ./uninstall.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./uninstall.sh"; exit 1; }
AGENT_LABEL=com.minh.forcecalls.endpoint
WD_LABEL=com.minh.forcecalls.endpoint-watchdog

# Watchdog first — otherwise it re-bootstraps the agent we're about to remove.
launchctl bootout "system/$WD_LABEL" 2>/dev/null || true
if [ -n "${SUDO_USER:-}" ]; then launchctl bootout "gui/$(id -u "$SUDO_USER")/$AGENT_LABEL" 2>/dev/null || true; fi
rm -f "/Library/LaunchDaemons/$WD_LABEL.plist" "/Library/LaunchAgents/$AGENT_LABEL.plist"
rm -f /usr/local/libexec/forcecalls-endpoint-watchdog.sh
rm -rf /etc/baresip
dseditgroup -o delete -n . _forcecalls 2>/dev/null || true
pkill baresip 2>/dev/null || true
echo "  ✓ endpoint removed (baresip itself left installed — brew uninstall baresip to drop it)"
