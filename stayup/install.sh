#!/bin/bash
# stayup — lid-closed-awake toggle. Root-owned GUI app that registers itself as a demonlock spare at
# install (demonlock ships no base list) + a passwordless pmset grant. Self-contained: declares its
# manifest, calls the shared install-lib.
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
SPARED=yes           # register with demonlock at install (root-owned Regime A) — demonlock ships no base list
provide_bundle() { dl_swift_bundle stayup.app; }
post_install() {
  dl_write_sudoers stayup \
    "$(dl_user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
  sudo -u "$(dl_user)" open "/Applications/$BUNDLE" 2>/dev/null || true
}

dl_run_manifest
