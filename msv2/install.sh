#!/bin/bash
# msv2 — desktop-group ⌘⇥ switcher. Root-owned GUI app; a demonlock compiled-default spare, so no
# explicit registration needed. Self-contained: declares its manifest, then calls the shared install-lib.
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
SPARED=no            # demonlock spares it as a compiled-in default (root-owned Regime A)
provide_bundle() { dl_swift_bundle msv2.app; }
post_install()   { sudo -u "$(dl_user)" open "/Applications/$BUNDLE" 2>/dev/null || true; }

dl_run_manifest
