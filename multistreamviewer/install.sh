#!/bin/bash
# multistreamviewer — desktop-group ⌘⇥ switcher. Root-owned GUI app that registers itself as a demonlock spare at
# install (demonlock ships no base list). Self-contained: declares its manifest, then calls install-lib.
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
SPARED=yes           # register with demonlock at install (root-owned Regime A) — demonlock ships no base list
provide_bundle() { dl_swift_bundle multistreamviewer.app; }

AGENT_LABEL=com.minh.multistreamviewer.agent
UID_TARGET="$(id -u "$(dl_user)")"

# Order matters (spec: bootout → pkill → deploy → bootstrap): killing a launchd-managed copy
# first would have KeepAlive respawn it mid-deploy, running a half-copied binary.
launchctl bootout "gui/$UID_TARGET/$AGENT_LABEL" 2>/dev/null || true
pkill -x multistreamviewer 2>/dev/null && sleep 1 || true

post_install() {
  dl_install_launchd "$APP_DIR/install/$AGENT_LABEL.plist" agent
  # install-lib swallows launchctl errors (e.g. no console session over SSH) — hard-verify.
  if ! launchctl print "gui/$UID_TARGET/$AGENT_LABEL" >/dev/null 2>&1; then
    echo "✗ agent not loaded in gui/$UID_TARGET — is a console session active? (over SSH: log in locally, then: launchctl bootstrap gui/$UID_TARGET /Library/LaunchAgents/$AGENT_LABEL.plist)"
    exit 1
  fi
}

dl_run_manifest
