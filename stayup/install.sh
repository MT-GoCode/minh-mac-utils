#!/bin/bash
# stayup — lid-closed-awake toggle. Root-owned GUI app + passwordless pmset grant; demonlock spare.
set -uo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$APP_DIR/../scripts/install-lib.sh"
dl_require_root

APP_TYPE=gui-app
APP_NAME=stayup
BUNDLE=stayup.app
BUNDLE_ID=com.minh.stayup
TEAM_ID=BULCQM9J2V
CLI=stayup
SPARED=yes
STOP_FIRST=yes                       # no launchd job; stop the menubar app so `open` below is the only instance
PROC_NAME=stayup
provide_bundle() { dl_swift_bundle stayup.app; }
post_install() {
  dl_write_sudoers stayup \
    "$(dl_user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0" || return 1
  pgrep -x stayup >/dev/null || sudo -u "$(dl_user)" open "/Applications/$BUNDLE" 2>/dev/null || true
}

dl_run_manifest || exit 1
