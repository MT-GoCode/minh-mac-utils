#!/bin/bash
# Install Demonlock: build+sign (as you), deploy (root), load both services, seed defaults.
# Run:  sudo ./install/install.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./install/install.sh"; exit 1; }
: "${SUDO_USER:?must be run via sudo (need SUDO_USER for the build keychain)}"
# Refuse a ROOT shell: SUDO_USER=root would seed enforcedUser=root (→ permanent STANDBY, never
# enforces your console user) AND, since root's keychain has no Dev ID cert, silently deploy the
# committed dist bundle instead of building the current source. Run as YOUR user via sudo.
[ "$SUDO_USER" != root ] || { echo "✗ don't run this from a root shell (SUDO_USER=root). Exit it, then: sudo ./demonlock/install.sh"; exit 1; }
USER_NAME="$SUDO_USER"
USER_UID="$(id -u "$USER_NAME")"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="/Library/Application Support/Demonlock"
cd "$HERE"

# Signing strategy: build from source ONLY if you actually have a Developer ID cert (fresh,
# stable signature) — checked in the USER's login keychain since we're running as root. Otherwise
# deploy the bundled dist/Demonlock.app, which is already Developer-ID-signed + timestamped; do NOT
# rebuild and ad-hoc-resign over it. Ad-hoc build is the last resort (toolchain but no cert/dist).
HAVE_DEVID="$(sudo -u "$USER_NAME" security find-identity -p codesigning -v 2>/dev/null \
              | grep -c 'Developer ID Application' || true)"
if [ -d "$HERE/dist/Demonlock.app" ] && [ "${HAVE_DEVID:-0}" -eq 0 ]; then
    echo "▸ no Developer ID cert — deploying the prebuilt, signed dist/Demonlock.app (no re-sign)"
    APP_SRC="$HERE/dist/Demonlock.app"
elif xcode-select -p >/dev/null 2>&1 && [ -f "$HERE/Package.swift" ]; then
    echo "▸ building + signing as $USER_NAME"
    sudo -u "$USER_NAME" bash install/build.sh
    APP_SRC="$HERE/Demonlock.app"
elif [ -d "$HERE/dist/Demonlock.app" ]; then
    echo "▸ deploying the prebuilt dist/Demonlock.app"
    APP_SRC="$HERE/dist/Demonlock.app"
else
    echo "✗ no Swift toolchain and no prebuilt dist/Demonlock.app."
    echo "  Install Xcode Command Line Tools (xcode-select --install), or copy this folder from a"
    echo "  Mac where you've built once (so dist/Demonlock.app is included)."
    exit 1
fi
[ -d "$APP_SRC" ] || { echo "✗ no app bundle to deploy"; exit 1; }

echo "▸ deploying app + CLI"
# A user-owned duplicate in ~/Applications could be launched instead of this one and
# would only be spared under the stricter signature rule — never leave one behind.
rm -rf "$(eval echo "~$USER_NAME")/Applications/Demonlock.app" /Applications/Demonlock.app
cp -R "$APP_SRC" /Applications/Demonlock.app
chown -R root:wheel /Applications/Demonlock.app
chmod -R go-w /Applications/Demonlock.app   # group/other-writable ⇒ fails spareVerified's owner test
xattr -dr com.apple.quarantine /Applications/Demonlock.app 2>/dev/null || true

cat > /usr/local/bin/demonlock <<'EOF'
#!/bin/bash
exec /Applications/Demonlock.app/Contents/MacOS/demonlock "$@"
EOF
chmod 755 /usr/local/bin/demonlock
chown root:wheel /usr/local/bin/demonlock

# Passwordless grants — both TIGHTEN-only (safe without admin; survive you dropping admin). They target
# the go-w ROOT-OWNED BUNDLE binary, NOT /usr/local/bin/demonlock: if /usr/local/bin were ever
# user-writable, a wrapper-path grant would be arbitrary root (review H4). We assert /usr/local ownership
# below and abort if it's writable.
#   arm    : turn enforcement ON.
#   nosudo : drop admin now (revoke). disarm (loosening) is NOT granted — it stays admin-gated.
# (The old `_zonedel *` grant is REMOVED: deleting a zone is NOT monotone — a zone referenced under NOT
#  loosens the policy — so zone deletion now goes through the admin/delayed path, not a free grant. H3.)
DL_BIN=/Applications/Demonlock.app/Contents/MacOS/demonlock
for d in /usr/local /usr/local/bin; do
  if [ -d "$d" ]; then
    owner="$(/usr/bin/stat -f%u "$d")"; mode="$(/usr/bin/stat -f%Lp "$d")"
    if [ "$owner" != "0" ] || [ "$(( 8#$mode & 8#022 ))" != "0" ]; then
      echo "✗ $d is not root-owned / is group/other-writable (uid=$owner mode=$mode)."
      echo "  A passwordless sudo grant there would be arbitrary root. Fix ownership first:"
      echo "    sudo chown root:wheel $d && sudo chmod go-w $d"
      exit 1
    fi
  fi
done
SUDOERS=/etc/sudoers.d/demonlock
{
  printf '%s ALL=(root) NOPASSWD: %s arm\n'    "$USER_NAME" "$DL_BIN"
  printf '%s ALL=(root) NOPASSWD: %s nosudo\n' "$USER_NAME" "$DL_BIN"
} > "$SUDOERS"
chown root:wheel "$SUDOERS"; chmod 440 "$SUDOERS"
visudo -cf "$SUDOERS" >/dev/null 2>&1 || { echo "  ⚠️  sudoers entry invalid — removing"; rm -f "$SUDOERS"; }

# Retire the standalone setuid `sudome` binary — demonlock now grants/revokes admin itself (Admin.swift).
# A leftover setuid-root sudome would be a parallel, delay-free path to admin, defeating the release
# valve (review L2). Remove the binary and its credentials dir if present.
if [ -e /usr/local/bin/sudome ] || [ -d /usr/local/etc/sudome ]; then
  echo "▸ removing retired sudome (demonlock manages admin internally now)"
  rm -f /usr/local/bin/sudome
  rm -rf /usr/local/etc/sudome
fi

echo "▸ seeding $SUPPORT (preserving existing settings)"
mkdir -p "$SUPPORT/logs"
WIFI_DEV="$(/usr/sbin/networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2; exit}')"
[ -n "$WIFI_DEV" ] || WIFI_DEV="en0"
# settings.json now persists the user's safe-apps, snooze-presets, and custom delays — so a reinstall
# must MERGE the per-machine keys (enforcedUser/wifiDevice), never overwrite the file. [review]
if [ -f "$SUPPORT/settings.json" ]; then
  /usr/bin/python3 - "$SUPPORT/settings.json" "$USER_NAME" "$WIFI_DEV" <<'PY'
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
  cat > "$SUPPORT/settings.json" <<EOF
{
  "enforcedUser" : "$USER_NAME",
  "wifiDevice" : "$WIFI_DEV"
}
EOF
fi
[ -f "$SUPPORT/armed" ]      || printf '0'    > "$SUPPORT/armed"     # installs DISARMED
[ -f "$SUPPORT/snooze" ]     || printf 'null' > "$SUPPORT/snooze"
[ -f "$SUPPORT/zones.json" ] || printf '[]'   > "$SUPPORT/zones.json"
chown -R root:wheel "$SUPPORT"
chmod 755 "$SUPPORT" "$SUPPORT/logs"
chmod 644 "$SUPPORT"/settings.json "$SUPPORT"/armed "$SUPPORT"/snooze "$SUPPORT"/zones.json 2>/dev/null || true
[ -f "$SUPPORT/policy.txt" ] && chmod 644 "$SUPPORT/policy.txt"
# Self-serve inbox: USER-owned so the no-sudo requests — `admin-release-valve request`/`abort`,
# `delay-set-policy`, and the map's "Save in 36h" (delayzones) — can drop a marker without sudo (the
# daemon stamps the real request time, so the delay can't be backdated). The pending state + config
# stay root-owned in $SUPPORT (root/daemon-written), world-readable for `status`.
mkdir -p "$SUPPORT/rv"
chown "$USER_NAME" "$SUPPORT/rv"
chmod 755 "$SUPPORT/rv"

echo "▸ installing launchd jobs"
cp install/com.demonlock.enforcerd.plist /Library/LaunchDaemons/
cp install/com.demonlock.agent.plist     /Library/LaunchAgents/
chown root:wheel /Library/LaunchDaemons/com.demonlock.enforcerd.plist /Library/LaunchAgents/com.demonlock.agent.plist
chmod 644        /Library/LaunchDaemons/com.demonlock.enforcerd.plist /Library/LaunchAgents/com.demonlock.agent.plist
# Point the agent log at the user's own Library/Logs, not world-writable /tmp (another local account
# could pre-create /tmp/demonlock-agent.log as a symlink, and the log leaks location/BSSIDs). [review L3]
USER_HOME="$(eval echo "~$USER_NAME")"
mkdir -p "$USER_HOME/Library/Logs" 2>/dev/null || true
chown "$USER_NAME" "$USER_HOME/Library/Logs" 2>/dev/null || true
/usr/bin/sed -i '' "s#/tmp/demonlock-agent.log#$USER_HOME/Library/Logs/demonlock-agent.log#g" \
    /Library/LaunchAgents/com.demonlock.agent.plist

echo "▸ (re)loading services"
# Boot both out first, pause so the old instances fully exit, then bootstrap (with a
# kickstart fallback if a job is somehow still registered) — avoids the bootstrap I/O race.
launchctl bootout system/com.demonlock.enforcerd 2>/dev/null || true
launchctl bootout "gui/$USER_UID/com.demonlock.agent" 2>/dev/null || true
sleep 2
launchctl bootstrap system /Library/LaunchDaemons/com.demonlock.enforcerd.plist 2>/dev/null \
    || launchctl kickstart -k system/com.demonlock.enforcerd 2>/dev/null || true
launchctl bootstrap "gui/$USER_UID" /Library/LaunchAgents/com.demonlock.agent.plist 2>/dev/null \
    || launchctl kickstart -k "gui/$USER_UID/com.demonlock.agent" 2>/dev/null || true

echo

echo "✓ installed — currently DISARMED. Next steps:"
echo "    demonlock scan                 # walk your office, capture BSSIDs (run WITHOUT sudo)"
echo "    demonlock zones                # add/delete zones (admin now, or delayed) on a map"
echo "    sudo demonlock setpolicy '...' # set the allow-policy"
echo "    demonlock status               # verify it evaluates"
echo "    sudo demonlock arm             # turn enforcement on"
echo
echo
echo "Spares: demonlock spares ONLY itself by default — your own apps register from their own"
echo "installers. For third-party utils (karabiner / alttab / raycast / …) run once:"
echo "    sudo ./demonlock/register-recommended-spares.sh"
echo
echo "If the agent isn't authorized for Location yet, run:  demonlock perm-ask"
