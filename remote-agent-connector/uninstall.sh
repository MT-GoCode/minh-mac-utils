#!/bin/bash
# Remove Remote Agent Connector. Leaves ~/.remote-agent-connector (CA, ssh keys, middleman config) intact
# unless --purge.  sudo ./uninstall.sh [--purge]
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/../scripts/install-lib.sh"
U="$(dl_console_user)"
sudo -u "$U" osascript -e 'quit app "RemoteAgentConnector"' >/dev/null 2>&1 || true; sleep 1
pkill -f "ssh -N -i .*remote-agent-connector/tunnel_key" 2>/dev/null || true
dl_uninstall_common --app RemoteAgentConnector.app --proc RemoteAgentConnector \
  --cli remote-agent-connector --cli rac --bid com.minh.remote-agent-connector \
  --support "/Users/$U/.remote-agent-connector" ${1:+"$1"}
echo "✓ uninstalled"
