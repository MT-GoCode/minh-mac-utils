#!/bin/bash
# Remove Foreman Uplink (app + running tunnel). Leaves ssh keys/config and the
# foreman-side provisioning in place — re-installing picks them right back up.
# Run:  sudo ./uninstall.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./uninstall.sh"; exit 1; }
USER_NAME="${SUDO_USER:-$(stat -f%Su /dev/console)}"
USER_HOME="$(eval echo "~$USER_NAME")"

sudo -u "$USER_NAME" osascript -e 'quit app "ForemanUplink"' >/dev/null 2>&1 || true
sleep 1
pkill -x ForemanUplink 2>/dev/null || true
pkill -f "ssh -N .*foreman-tunnel" 2>/dev/null || true
rm -rf /Applications/ForemanUplink.app "$USER_HOME/Applications/ForemanUplink.app"
echo "✓ uninstalled (ssh keys and foreman-side config left intact)"
