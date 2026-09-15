#!/bin/bash
# Install Remote Agent Connector: build+sign as your user, deploy the app root-owned, install the
# `remote-agent-connector` + `rac` CLI, launch (registers a Login Item). Run:  sudo ./install.sh
# NOTE: reinstalling KILLS the reverse tunnel (this is the SSH lifeline) — run it from a local terminal,
# never from a session riding that tunnel. install-all skips rac over SSH for exactly this reason.
set -uo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$APP_DIR/../scripts/install-lib.sh"
dl_require_root
cd "$APP_DIR"

APP_TYPE=gui-app
APP_NAME=remote-agent-connector
BUNDLE=RemoteAgentConnector.app
BUNDLE_ID=com.minh.remote-agent-connector
TEAM_ID=BULCQM9J2V
SPARED=yes
STOP_FIRST=yes                       # a GUI app: replacing the bundle under a running copy leaves two
PROC_NAME=RemoteAgentConnector
STOP_PRE=rac_graceful_stop           # osascript quit + reap the orphaned `ssh -N` tunnel child
USER_NAME="$(dl_user)"; USER_HOME="$(dl_user_home)"

rac_graceful_stop() {
  sudo -u "$USER_NAME" osascript -e 'quit app "RemoteAgentConnector"' >/dev/null 2>&1 || true
  sleep 1
  pkill -f "ssh -N -i .*remote-agent-connector/tunnel_key" 2>/dev/null || true
}

# Single-file swiftc build — no Package.swift, no committed dist. CLT is required.
provide_bundle() { dl_pick_bundle "$APP_DIR/RemoteAgentConnector.app" "$APP_DIR/build.sh"; }

post_install() {
  echo "▸ installing CLI: /usr/local/bin/remote-agent-connector (+ rac)"
  dl_install_script_cli remote-agent-connector "$APP_DIR/remote-agent-connector" || return 1
  ln -sf /usr/local/bin/remote-agent-connector /usr/local/bin/rac
  echo "▸ scaffolding a blank config (you fill it in, then run: rac setup)"
  sudo -u "$USER_NAME" /usr/local/bin/remote-agent-connector init || true    # refuses if it exists — fine
  echo "▸ launching as $USER_NAME (registers a Login Item, shows in Dock)"
  sudo -u "$USER_NAME" open "/Applications/$BUNDLE"
}

dl_run_manifest || exit 1

cat <<MSG
✓ installed.  Next:
  1. Dock icon → right-click → "Get Permissions" (Screen Recording, Accessibility, Automation).
  2. Edit ~/.remote-agent-connector/config — set MIDDLEMAN and MACHINE_NAME.
  3. rac setup       (converges everything; rolls back if anything fails)
     rac status      (check the tunnel any time)
  Verify it survives a lockout:  demonlock test-lockout
MSG
