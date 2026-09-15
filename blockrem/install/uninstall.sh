#!/bin/bash
# Uninstall Blockrem.  sudo ./install/uninstall.sh [--purge]   (--purge also removes the schedule/state)
set -uo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/../scripts/install-lib.sh"
dl_uninstall_common --app Blockrem.app --proc blockrem --cli blockrem --bid com.minh.blockrem \
  --daemon com.minh.blockrem.enforcerd --agent com.minh.blockrem.agent \
  --support "/Library/Application Support/Blockrem" ${1:+"$1"}
echo "✓ uninstalled"
