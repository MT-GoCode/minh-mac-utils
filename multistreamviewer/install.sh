#!/bin/bash
# multistreamviewer — desktop-group ⌘⇥ switcher. Root-owned GUI app + LaunchAgent (KeepAlive relaunches
# crashes/kills; menu Quit stays quit until next login); registers itself as a demonlock spare.
set -uo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$APP_DIR/../scripts/install-lib.sh"
dl_require_root

APP_TYPE=gui-app
APP_NAME=multistreamviewer
BUNDLE=multistreamviewer.app
BUNDLE_ID=com.minh.multistreamviewer
TEAM_ID=BULCQM9J2V
CLI=multistreamviewer
SPARED=yes
STOP_FIRST=yes                       # KeepAlive={SuccessfulExit:false} would respawn the app mid-copy
PROC_NAME=multistreamviewer
AGENT_LABEL=com.minh.multistreamviewer.agent
provide_bundle() { dl_swift_bundle multistreamviewer.app; }
post_install()   { dl_install_launchd "$APP_DIR/install/$AGENT_LABEL.plist" agent; }   # verifies state=running

dl_run_manifest || exit 1
