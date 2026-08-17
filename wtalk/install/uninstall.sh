#!/bin/bash
# Uninstall wtalk.  sudo ./install/uninstall.sh [--purge]
# Leaves ~/.wtalk (your keys, config, history, logs) unless --purge.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./install/uninstall.sh"; exit 1; }
USER_NAME="${SUDO_USER:-$(stat -f %Su /dev/console)}"
USER_UID="$(id -u "$USER_NAME")"
USER_HOME="$(/usr/bin/dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')"
[ -n "$USER_HOME" ] || USER_HOME="/Users/$USER_NAME"

echo "▸ stopping + unloading the agent"
sudo -u "$USER_NAME" launchctl bootout "gui/$USER_UID/com.minh.wtalk.agent" 2>/dev/null || true
pkill -x wtalk 2>/dev/null || true

echo "▸ removing files"
rm -f  /Library/LaunchAgents/com.minh.wtalk.agent.plist
rm -f  "$USER_HOME/Library/LaunchAgents/com.minh.wtalk.agent.plist"   # old user-owned plist, if any
rm -rf /Applications/wtalk.app
rm -f  /usr/local/bin/wtalk
rm -f  "$USER_HOME/.local/bin/wtalk"                             # old dev-era PATH symlink, if any

if [ "${1:-}" = "--purge" ]; then
    rm -rf "$USER_HOME/.wtalk"
    echo "  purged $USER_HOME/.wtalk (keys, config, prompts, history, logs)"
else
    echo "  kept $USER_HOME/.wtalk (keys, config, history). Remove with --purge."
fi

echo "✓ uninstalled"
echo "  (optional) revoke perms:  tccutil reset Microphone com.minh.wtalk;"
echo "                            tccutil reset Accessibility com.minh.wtalk"
