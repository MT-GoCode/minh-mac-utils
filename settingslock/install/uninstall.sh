#!/bin/bash
# Remove settingslock entirely. Run with sudo.
set -euo pipefail
[ "$(id -u)" -ne 0 ] && { echo "Run with sudo: sudo $0"; exit 1; }

UID_NUM="${SUDO_UID:-$(id -u)}"
WATCH="com.settingslock.watch"; GUARD="com.settingslock.guard"

# Guard FIRST — otherwise it re-bootstraps the watcher as we remove it.
launchctl bootout "system/$GUARD" 2>/dev/null || true
launchctl bootout "gui/$UID_NUM/$WATCH" 2>/dev/null || true

rm -f /usr/local/bin/settingslock \
      "/Library/LaunchAgents/$WATCH.plist" \
      "/Library/LaunchDaemons/$GUARD.plist" \
      /tmp/settingslock-*.log /tmp/settingslock.heartbeat
rm -rf /usr/local/etc/settingslock

echo "settingslock removed. (Its entry may linger in Privacy & Security ▸ Accessibility — remove it there.)"
