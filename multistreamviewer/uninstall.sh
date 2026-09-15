#!/bin/bash
# Remove multistreamviewer.  sudo ./uninstall.sh [--purge]   (--purge also removes its prefs/state)
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/../scripts/install-lib.sh"
U="$(dl_console_user)"
dl_uninstall_common --app multistreamviewer.app --proc multistreamviewer --cli multistreamviewer \
  --bid com.minh.multistreamviewer --agent com.minh.multistreamviewer.agent \
  --support "/Users/$U/Library/Application Support/multistreamviewer" ${1:+"$1"}
echo "✓ uninstalled   (permissions kept; to revoke: tccutil reset Accessibility com.minh.multistreamviewer)"
