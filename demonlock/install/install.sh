#!/bin/bash
# Install Demonlock: build+sign (as you), deploy (root), seed defaults, load both services.
# Run:  sudo ./install.sh [--prebuilt]     (--prebuilt = deploy the committed dist/, no build, no keychain)
set -uo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$APP_DIR/../scripts/install-lib.sh"
dl_require_root
[ "${1:-}" = "--prebuilt" ] && export PREBUILT=1
cd "$APP_DIR"

APP_TYPE=gui-app
APP_NAME=demonlock
BUNDLE=Demonlock.app
BUNDLE_ID=com.minh.demonlock
TEAM_ID=BULCQM9J2V
CLI=demonlock
CLI_WRAPPER=yes      # /usr/local/bin/demonlock is a wrapper script (parity with every installed machine)
SPARED=no            # demonlock spares itself
SUPPORT="/Library/Application Support/Demonlock"
USER_NAME="$(dl_user)"
USER_HOME="$(dl_user_home)"

# NOT stopped before deploy: the enforcer keeps running through the copy (the old inode stays mapped);
# post_install's dl_install_launchd does bootout → bootstrap, so there is no enforcement gap while armed.
provide_bundle() { dl_pick_bundle "$APP_DIR/Demonlock.app" "$APP_DIR/install/build.sh" "$APP_DIR/dist/Demonlock.app"; }

post_install() {
  # Passwordless grants — both TIGHTEN-only (safe without admin; survive you dropping admin). They target
  # the go-w ROOT-OWNED BUNDLE binary, NOT /usr/local/bin/demonlock: if /usr/local/bin were ever
  # user-writable, a wrapper-path grant would be arbitrary root (review H4). dl_write_sudoers asserts
  # /usr/local ownership and aborts if it's writable. Written BEFORE launchd reload so an invalid file
  # stops here, not after the services bounced.
  #   arm    : turn enforcement ON.   nosudo : drop admin now (revoke).   disarm stays admin-gated.
  local bin=/Applications/Demonlock.app/Contents/MacOS/demonlock
  dl_write_sudoers demonlock \
    "$USER_NAME ALL=(root) NOPASSWD: $bin arm" \
    "$USER_NAME ALL=(root) NOPASSWD: $bin nosudo" || return 1

  # Retire the standalone setuid `sudome` binary — demonlock grants/revokes admin itself (Admin.swift).
  # A leftover setuid-root sudome would be a parallel, delay-free path to admin (review L2).
  if [ -e /usr/local/bin/sudome ] || [ -d /usr/local/etc/sudome ]; then
    echo "▸ removing retired sudome (demonlock manages admin internally now)"
    rm -f /usr/local/bin/sudome; rm -rf /usr/local/etc/sudome
  fi

  echo "▸ seeding $SUPPORT (preserving existing settings)"
  mkdir -p "$SUPPORT/logs"
  local wifi; wifi="$(/usr/sbin/networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2; exit}')"
  [ -n "$wifi" ] || wifi="en0"
  # settings.json persists the user's safe-apps, snooze-presets, and custom delays — so a reinstall
  # must MERGE the per-machine keys (enforcedUser/wifiDevice), never overwrite the file. (blockrem
  # deliberately does the opposite; the two are not the same and are not shared.)
  if [ -f "$SUPPORT/settings.json" ]; then
    /usr/bin/python3 - "$SUPPORT/settings.json" "$USER_NAME" "$wifi" <<'PY'
import json, sys
path, user, wifi = sys.argv[1:4]
try:
    d = json.load(open(path));  d = d if isinstance(d, dict) else {}
except Exception:
    d = {}
d["enforcedUser"], d["wifiDevice"] = user, wifi
json.dump(d, open(path, "w"), indent=2, sort_keys=True)
PY
  else
    printf '{\n  "enforcedUser" : "%s",\n  "wifiDevice" : "%s"\n}\n' "$USER_NAME" "$wifi" > "$SUPPORT/settings.json"
  fi
  [ -f "$SUPPORT/armed" ]      || printf '0'    > "$SUPPORT/armed"     # installs DISARMED
  [ -f "$SUPPORT/snooze" ]     || printf 'null' > "$SUPPORT/snooze"
  [ -f "$SUPPORT/zones.json" ] || printf '[]'   > "$SUPPORT/zones.json"
  # Self-serve inbox `rv/` is USER-owned (no-sudo request markers); everything else root-owned. The
  # recursive chown must NOT touch rv/ — it would re-own a pending marker to root and the daemon's
  # owner check would reject it.
  mkdir -p "$SUPPORT/rv"
  find "$SUPPORT" -path "$SUPPORT/rv" -prune -o -exec chown root:wheel {} +
  chown "$USER_NAME" "$SUPPORT/rv"
  chmod 755 "$SUPPORT" "$SUPPORT/logs" "$SUPPORT/rv"
  chmod 644 "$SUPPORT"/settings.json "$SUPPORT"/armed "$SUPPORT"/snooze "$SUPPORT"/zones.json 2>/dev/null || true
  [ -f "$SUPPORT/policy.txt" ] && chmod 644 "$SUPPORT/policy.txt"

  echo "▸ installing launchd jobs"
  # The agent log goes to the user's own Library/Logs, not world-writable /tmp (another local account
  # could pre-create /tmp/demonlock-agent.log as a symlink, and the log leaks location/BSSIDs).
  mkdir -p "$USER_HOME/Library/Logs" 2>/dev/null || true
  chown "$USER_NAME" "$USER_HOME/Library/Logs" 2>/dev/null || true
  dl_install_launchd "$APP_DIR/install/com.minh.demonlock.enforcerd.plist" daemon || return 1
  dl_install_launchd "$APP_DIR/install/com.minh.demonlock.agent.plist" agent \
    --sed "/tmp/demonlock-agent.log=$USER_HOME/Library/Logs/demonlock-agent.log" || return 1
}

dl_run_manifest || exit 1

echo
echo "✓ installed. If this is a first install it is DISARMED; a reinstall keeps your armed/policy state."
echo "    demonlock scan                 # walk your office, capture BSSIDs (run WITHOUT sudo)"
echo "    demonlock zones                # add/delete zones (admin now, or delayed) on a map"
echo "    sudo demonlock setpolicy '...' # set the allow-policy"
echo "    demonlock status               # verify it evaluates"
echo "    sudo demonlock arm             # turn enforcement on"
echo
echo "Spares: demonlock spares ONLY itself by default — your own apps register from their own"
echo "installers. For third-party utils (karabiner / alttab / raycast / …) run once:"
echo "    sudo ./demonlock/register-recommended-spares.sh"
echo
echo "If the agent isn't authorized for Location yet, run:  demonlock perm-ask"
