#!/bin/bash
# Install Blockrem: build+sign (as you), deploy (root), seed defaults, load both services.
# Run:  sudo ./install.sh [--prebuilt]     (--prebuilt = deploy a committed dist/, if one exists)
set -uo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$APP_DIR/../scripts/install-lib.sh"
dl_require_root
[ "${1:-}" = "--prebuilt" ] && export PREBUILT=1
cd "$APP_DIR"

APP_TYPE=gui-app
APP_NAME=blockrem
BUNDLE=Blockrem.app
BUNDLE_ID=com.minh.blockrem
TEAM_ID=BULCQM9J2V
CLI=blockrem
CLI_WRAPPER=yes
SPARED=yes           # the LSUIElement agent would be force-closed by a demonlock lockout — spare it
SUPPORT="/Library/Application Support/Blockrem"
USER_NAME="$(dl_user)"
USER_HOME="$(dl_user_home)"

# Not stopped before deploy (same reasoning as demonlock: the root daemon keeps running through the copy).
provide_bundle() { dl_pick_bundle "$APP_DIR/Blockrem.app" "$APP_DIR/install/build.sh" "$APP_DIR/dist/Blockrem.app"; }

post_install() {
  echo "▸ seeding $SUPPORT (defaults only if absent)"
  mkdir -p "$SUPPORT/logs" "$SUPPORT/data"
  # Seed ONLY the per-machine key (enforcedUser) and OVERWRITE it deliberately: behavioral defaults
  # live in the code (Settings.swift) and are decoded leniently, so a changed default takes effect
  # instead of being shadowed by an old file. Nothing else writes settings.json. (demonlock MERGES
  # its file because it holds user state — the two are different on purpose.)
  printf '{\n  "enforcedUser" : "%s"\n}\n' "$USER_NAME" > "$SUPPORT/settings.json"
  [ -f "$SUPPORT/active.json" ]        || printf '{}'   > "$SUPPORT/active.json"
  [ -f "$SUPPORT/data/schedule.json" ] || printf '[]'   > "$SUPPORT/data/schedule.json"
  [ -f "$SUPPORT/data/snooze" ]        || printf 'null' > "$SUPPORT/data/snooze"
  # Root owns the app, daemon, plists, and settings (uninstall/stop need sudo; the overlay is
  # un-quittable), but data/ is owned by the enforced user so set/delete/snooze run WITHOUT sudo.
  find "$SUPPORT" -path "$SUPPORT/data" -prune -o -exec chown root:wheel {} +
  chmod 755 "$SUPPORT" "$SUPPORT/logs"
  chmod 644 "$SUPPORT/settings.json" "$SUPPORT/active.json"
  chown -R "$USER_NAME" "$SUPPORT/data"
  chmod 755 "$SUPPORT/data"
  chmod 644 "$SUPPORT/data/schedule.json" "$SUPPORT/data/snooze"

  echo "▸ installing launchd jobs"
  mkdir -p "$USER_HOME/Library/Logs" 2>/dev/null || true
  chown "$USER_NAME" "$USER_HOME/Library/Logs" 2>/dev/null || true
  dl_install_launchd "$APP_DIR/install/com.minh.blockrem.enforcerd.plist" daemon || return 1
  dl_install_launchd "$APP_DIR/install/com.minh.blockrem.agent.plist" agent \
    --sed "/tmp/blockrem-agent.log=$USER_HOME/Library/Logs/blockrem-agent.log" || return 1
}

dl_run_manifest || exit 1

echo
echo "✓ installed. Next steps (all user-runnable — NO sudo):"
echo "    blockrem perm-ask                # grant Accessibility (needed to freeze keyboard/mouse)"
echo "    blockrem set --weekly \"*0800\" --label \"water break\" --duration 30"
echo "    blockrem list                    # verify"
echo
echo "Only install/uninstall need sudo — that's what makes the overlay un-quittable. Input-freeze"
echo "needs Accessibility ▸ turn ON \"Blockrem\" (the visual cover works without it)."
echo "Verify it survives a demonlock lockout:  demonlock test-lockout"
