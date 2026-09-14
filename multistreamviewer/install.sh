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

# Build FIRST — a failed build must leave the running copy and its agent untouched.
ART="$(dl_swift_bundle multistreamviewer.app)" || { echo "✗ multistreamviewer: build failed"; exit 1; }
provide_bundle() { echo "$ART"; }

# Then stop, in this order (spec: bootout → pkill → deploy → bootstrap): killing a
# launchd-managed copy first would have KeepAlive respawn it mid-deploy.
launchctl bootout "gui/$UID_TARGET/$AGENT_LABEL" 2>/dev/null || true
pkill -x multistreamviewer 2>/dev/null && sleep 1 || true

post_install() { dl_install_launchd "$APP_DIR/install/$AGENT_LABEL.plist" agent; }

dl_run_manifest || exit 1

# Hard verify AFTER the manifest (so a load failure can't skip demonlock spare registration):
# install-lib swallows launchctl errors, e.g. installing over SSH with no console session.
if ! launchctl print "gui/$UID_TARGET/$AGENT_LABEL" >/dev/null 2>&1; then
  echo "✗ agent not loaded in gui/$UID_TARGET — is a console session active? (over SSH: log in locally, then: launchctl bootstrap gui/$UID_TARGET /Library/LaunchAgents/$AGENT_LABEL.plist)"
  exit 1
fi
