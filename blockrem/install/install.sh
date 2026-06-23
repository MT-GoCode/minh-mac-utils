#!/bin/bash
# Install Blockrem: build+sign (as you), deploy (root), load both services, seed defaults.
# Run:  sudo ./install/install.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./install/install.sh"; exit 1; }
: "${SUDO_USER:?must be run via sudo (need SUDO_USER for the build keychain)}"
USER_NAME="$SUDO_USER"
USER_UID="$(id -u "$USER_NAME")"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="/Library/Application Support/Blockrem"
cd "$HERE"

# Signing strategy (same ladder as the rest of minh-mac-utils): build from source ONLY if you
# actually have a Developer ID cert (fresh, stable signature) — checked in the USER's login keychain
# since we're running as root. Otherwise deploy the bundled dist/Blockrem.app, which is already
# Developer-ID-signed + timestamped; don't rebuild and ad-hoc-resign over it. Ad-hoc build is the
# last resort (toolchain but no cert/dist).
HAVE_DEVID="$(sudo -u "$USER_NAME" security find-identity -p codesigning -v 2>/dev/null \
              | grep -c 'Developer ID Application' || true)"
if [ -d "$HERE/dist/Blockrem.app" ] && [ "${HAVE_DEVID:-0}" -eq 0 ]; then
    echo "▸ no Developer ID cert — deploying the prebuilt, signed dist/Blockrem.app (no re-sign)"
    APP_SRC="$HERE/dist/Blockrem.app"
elif xcode-select -p >/dev/null 2>&1 && [ -f "$HERE/Package.swift" ]; then
    echo "▸ building + signing as $USER_NAME"
    sudo -u "$USER_NAME" bash install/build.sh
    APP_SRC="$HERE/Blockrem.app"
elif [ -d "$HERE/dist/Blockrem.app" ]; then
    echo "▸ deploying the prebuilt dist/Blockrem.app"
    APP_SRC="$HERE/dist/Blockrem.app"
else
    echo "✗ no Swift toolchain and no prebuilt dist/Blockrem.app."
    echo "  Install Xcode Command Line Tools (xcode-select --install), or copy this folder from a"
    echo "  Mac where you've built once (so dist/Blockrem.app is included)."
    exit 1
fi
[ -d "$APP_SRC" ] || { echo "✗ no app bundle to deploy"; exit 1; }

echo "▸ deploying app + CLI"
rm -rf /Applications/Blockrem.app
cp -R "$APP_SRC" /Applications/Blockrem.app
chown -R root:wheel /Applications/Blockrem.app
xattr -dr com.apple.quarantine /Applications/Blockrem.app 2>/dev/null || true

cat > /usr/local/bin/blockrem <<'EOF'
#!/bin/bash
exec /Applications/Blockrem.app/Contents/MacOS/blockrem "$@"
EOF
chmod 755 /usr/local/bin/blockrem
chown root:wheel /usr/local/bin/blockrem

echo "▸ seeding $SUPPORT (defaults only if absent)"
mkdir -p "$SUPPORT/logs" "$SUPPORT/data"
# Seed only the per-machine key (enforcedUser); behavioral defaults live in the code (Settings.swift)
# and are decoded leniently, so changing a default actually takes effect instead of being shadowed.
cat > "$SUPPORT/settings.json" <<EOF
{
  "enforcedUser" : "$USER_NAME"
}
EOF
[ -f "$SUPPORT/active.json" ]        || printf '{}'   > "$SUPPORT/active.json"
[ -f "$SUPPORT/data/schedule.json" ] || printf '[]'   > "$SUPPORT/data/schedule.json"
[ -f "$SUPPORT/data/snooze" ]        || printf 'null' > "$SUPPORT/data/snooze"
# Root owns the app, daemon, plists, and settings (so uninstall/stop need sudo and the overlay is
# un-quittable), but the data subdir is owned by the enforced user — that's what lets set/delete/
# snooze run WITHOUT sudo (atomic writes need a writable dir).
chown -R root:wheel "$SUPPORT"
chmod 755 "$SUPPORT" "$SUPPORT/logs"
chmod 644 "$SUPPORT/settings.json" "$SUPPORT/active.json"
chown -R "$USER_NAME" "$SUPPORT/data"
chmod 755 "$SUPPORT/data"
chmod 644 "$SUPPORT/data/schedule.json" "$SUPPORT/data/snooze"

echo "▸ installing launchd jobs"
cp install/com.blockrem.enforcerd.plist /Library/LaunchDaemons/
cp install/com.blockrem.agent.plist     /Library/LaunchAgents/
chown root:wheel /Library/LaunchDaemons/com.blockrem.enforcerd.plist /Library/LaunchAgents/com.blockrem.agent.plist
chmod 644        /Library/LaunchDaemons/com.blockrem.enforcerd.plist /Library/LaunchAgents/com.blockrem.agent.plist

echo "▸ (re)loading services"
launchctl bootout system/com.blockrem.enforcerd 2>/dev/null || true
launchctl bootout "gui/$USER_UID/com.blockrem.agent" 2>/dev/null || true
sleep 2
launchctl bootstrap system /Library/LaunchDaemons/com.blockrem.enforcerd.plist 2>/dev/null \
    || launchctl kickstart -k system/com.blockrem.enforcerd 2>/dev/null || true
launchctl bootstrap "gui/$USER_UID" /Library/LaunchAgents/com.blockrem.agent.plist 2>/dev/null \
    || launchctl kickstart -k "gui/$USER_UID/com.blockrem.agent" 2>/dev/null || true

echo
echo "✓ installed. Next steps (all user-runnable — NO sudo):"
echo "    blockrem perm-ask                # grant Accessibility (needed to freeze keyboard/mouse)"
echo "    blockrem set --weekly *0800 --label \"water break\" --duration 30"
echo "    blockrem list                    # verify"
echo
echo "Only install/uninstall need sudo — that's what makes the overlay un-quittable. Input-freeze"
echo "needs Accessibility ▸ turn ON \"Blockrem\" (the visual cover works without it)."
