#!/bin/bash
# Uninstall wtalk.  sudo ./install/uninstall.sh [--purge]   (--purge also removes ~/.wtalk: keys, config, history)
set -uo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/../scripts/install-lib.sh"
U="$(dl_console_user)"; H="$(/usr/bin/dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"; H="${H:-/Users/$U}"
dl_uninstall_common --app wtalk.app --proc wtalk --cli wtalk --bid com.minh.wtalk --agent com.minh.wtalk.agent \
  --support "$H/.wtalk" ${1:+"$1"}
rm -f "$H/Library/LaunchAgents/com.minh.wtalk.agent.plist" "$H/.local/bin/wtalk"
echo "✓ uninstalled"
echo "  (optional) revoke perms:  tccutil reset Microphone com.minh.wtalk; tccutil reset Accessibility com.minh.wtalk"
