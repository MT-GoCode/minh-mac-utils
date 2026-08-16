#!/bin/bash
# Remove Remote Agent Connector. Leaves your CA, ssh keys, and middleman config intact
# (delete ~/.remote-agent-connector by hand if you want a clean slate).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./uninstall.sh"; exit 1; }
: "${SUDO_USER:?run via sudo}"

sudo -u "$SUDO_USER" osascript -e 'quit app "RemoteAgentConnector"' >/dev/null 2>&1 || true
sleep 1
pkill -x RemoteAgentConnector 2>/dev/null || true
pkill -f "ssh -N -i .*remote-agent-connector/tunnel_key" 2>/dev/null || true

rm -rf /Applications/RemoteAgentConnector.app
rm -f /usr/local/bin/remote-agent-connector /usr/local/bin/rac
echo "✓ removed app + CLI. (CA/keys/config under ~/.remote-agent-connector kept.)"
