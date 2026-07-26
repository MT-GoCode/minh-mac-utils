#!/bin/bash
# Install Demonlock: build+sign (as you), deploy (root), load both services, seed defaults.
# Run:  sudo ./install/install.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./install/install.sh"; exit 1; }
: "${SUDO_USER:?must be run via sudo (need SUDO_USER for the build keychain)}"
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
rm -rf /Applications/Demonlock.app
cp -R "$APP_SRC" /Applications/Demonlock.app
chown -R root:wheel /Applications/Demonlock.app
xattr -dr com.apple.quarantine /Applications/Demonlock.app 2>/dev/null || true

cat > /usr/local/bin/demonlock <<'EOF'
#!/bin/bash
exec /Applications/Demonlock.app/Contents/MacOS/demonlock "$@"
EOF
chmod 755 /usr/local/bin/demonlock
chown root:wheel /usr/local/bin/demonlock

# Passwordless grant for zone DELETION only — deleting a zone only ever *tightens* the policy,
# so it's safe to allow without admin (and it survives you removing your admin rights). Adding a
# zone still needs admin. The _zonedel subcommand only removes a named zone, nothing else.
SUDOERS=/etc/sudoers.d/demonlock
printf '%s ALL=(root) NOPASSWD: /usr/local/bin/demonlock _zonedel *\n' "$USER_NAME" > "$SUDOERS"
chown root:wheel "$SUDOERS"; chmod 440 "$SUDOERS"
visudo -cf "$SUDOERS" >/dev/null 2>&1 || { echo "  ⚠️  sudoers entry invalid — removing"; rm -f "$SUDOERS"; }

echo "▸ seeding $SUPPORT (defaults only if absent)"
mkdir -p "$SUPPORT/logs"
WIFI_DEV="$(/usr/sbin/networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2; exit}')"
[ -n "$WIFI_DEV" ] || WIFI_DEV="en0"
# Seed ONLY the per-machine keys; every behavioral tunable is owned by the code defaults
# (Settings.swift / LOCATION-MODEL.md) and decoded leniently, so changing a default actually
# takes effect instead of being shadowed by a stale file. Rewritten each install to pick up
# enforcedUser/wifiDevice; behavior keys deliberately absent.
cat > "$SUPPORT/settings.json" <<EOF
{
  "enforcedUser" : "$USER_NAME",
  "wifiDevice" : "$WIFI_DEV"
}
EOF
[ -f "$SUPPORT/armed" ]      || printf '0'    > "$SUPPORT/armed"     # installs DISARMED
[ -f "$SUPPORT/snooze" ]     || printf 'null' > "$SUPPORT/snooze"
[ -f "$SUPPORT/zones.json" ] || printf '[]'   > "$SUPPORT/zones.json"
chown -R root:wheel "$SUPPORT"
chmod 755 "$SUPPORT" "$SUPPORT/logs"
chmod 644 "$SUPPORT"/settings.json "$SUPPORT"/armed "$SUPPORT"/snooze "$SUPPORT"/zones.json 2>/dev/null || true
[ -f "$SUPPORT/policy.txt" ] && chmod 644 "$SUPPORT/policy.txt"
# Release-valve inbox: USER-owned so `release-valve --request`/`abort` drop a marker without sudo
# (the daemon stamps the real request time, so the delay can't be backdated). Config + state stay
# root-owned in $SUPPORT (root/daemon-written), world-readable for `status`.
mkdir -p "$SUPPORT/rv"
chown "$USER_NAME" "$SUPPORT/rv"
chmod 755 "$SUPPORT/rv"

echo "▸ installing launchd jobs"
cp install/com.demonlock.enforcerd.plist /Library/LaunchDaemons/
cp install/com.demonlock.agent.plist     /Library/LaunchAgents/
chown root:wheel /Library/LaunchDaemons/com.demonlock.enforcerd.plist /Library/LaunchAgents/com.demonlock.agent.plist
chmod 644        /Library/LaunchDaemons/com.demonlock.enforcerd.plist /Library/LaunchAgents/com.demonlock.agent.plist

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
echo "    demonlock zones                # add zones (admin) / delete zones (free) on a map"
echo "    sudo demonlock setpolicy '...' # set the allow-policy"
echo "    demonlock status               # verify it evaluates"
echo "    sudo demonlock arm             # turn enforcement on"
echo
echo "If the agent isn't authorized for Location yet, run:  demonlock perm-ask"
