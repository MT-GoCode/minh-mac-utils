#!/bin/bash
# msv2 — desktop-group ⌘⇥ switcher. Root-owned GUI app that registers itself as a demonlock spare at
# install (demonlock ships no base list). Self-contained: declares its manifest, then calls install-lib.
set -uo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$APP_DIR/../scripts/install-lib.sh"
dl_require_root

APP_TYPE=gui-app
APP_NAME=msv2
BUNDLE=msv2.app
BUNDLE_ID=com.minh.msv2
TEAM_ID=BULCQM9J2V
CLI=msv2
SPARED=yes           # register with demonlock at install (root-owned Regime A) — demonlock ships no base list
provide_bundle() { dl_swift_bundle msv2.app; }
post_install()   { sudo -u "$(dl_user)" open "/Applications/$BUNDLE" 2>/dev/null || true; }

dl_run_manifest
