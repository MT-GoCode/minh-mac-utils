#!/bin/bash
# Remove stayup. Restores normal sleep first — quitting the app alone would leave the Mac unable to
# sleep (the setting lives in macOS power management).  sudo ./uninstall.sh [--purge]
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/../scripts/install-lib.sh"
/usr/bin/pmset -a disablesleep 0 || true
dl_uninstall_common --app stayup.app --proc stayup --cli stayup --bid com.minh.stayup ${1:+"$1"}
rm -f /etc/sudoers.d/stayup
echo "✓ uninstalled"
