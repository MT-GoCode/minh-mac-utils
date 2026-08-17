#!/bin/bash
# Install forcecalls: build + sign (as you), deploy root-owned, collect SignalWire creds, load the
# root daemon and the GUI agent.
# Run:  sudo ./install.sh [--reset-creds]
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./install.sh"; exit 1; }
: "${SUDO_USER:?must be run via sudo (need SUDO_USER to know whose inbox to trust)}"
# Refuse a ROOT shell: SUDO_USER=root would seed enforcedUser=root, so the daemon would trust markers
# from root's inbox instead of yours — i.e. no forced call you could ever manage. The agent also runs
# in YOUR gui session and signs against YOUR login keychain.
[ "$SUDO_USER" != root ] || { echo "✗ don't run this from a root shell (SUDO_USER=root). Exit it, then: sudo ./install.sh"; exit 1; }

USER_NAME="$SUDO_USER"
USER_UID="$(id -u "$USER_NAME")"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="/Library/Application Support/Forcecalls"
BIN=/usr/local/libexec/forcecalls
cd "$HERE"

# ── build ────────────────────────────────────────────────────────────────────────────────────────
# Same signing strategy as the rest of minh-mac-utils: build from source only when you actually hold
# a Developer ID cert (checked in the USER's keychain, since we're root); otherwise deploy the
# prebuilt, already-signed dist/ copies rather than ad-hoc re-signing over them.
HAVE_DEVID="$(sudo -u "$USER_NAME" security find-identity -p codesigning -v 2>/dev/null \
              | grep -c 'Developer ID Application' || true)"
if [ -d "$HERE/dist/Forcecalls.app" ] && [ -x "$HERE/dist/forcecalls" ] && [ "${HAVE_DEVID:-0}" -eq 0 ]; then
    echo "▸ no Developer ID cert — deploying the prebuilt, signed dist/ copies (no re-sign)"
    CLI_SRC="$HERE/dist/forcecalls"; APP_SRC="$HERE/dist/Forcecalls.app"
elif xcode-select -p >/dev/null 2>&1 && [ -f "$HERE/Package.swift" ]; then
    echo "▸ building + signing as $USER_NAME"
    sudo -u "$USER_NAME" bash install/build.sh
    CLI_SRC="$(sudo -u "$USER_NAME" swift build -c release --show-bin-path --package-path "$HERE")/forcecalls"
    APP_SRC="$HERE/Forcecalls.app"
elif [ -d "$HERE/dist/Forcecalls.app" ] && [ -x "$HERE/dist/forcecalls" ]; then
    echo "▸ deploying the prebuilt dist/ copies"
    CLI_SRC="$HERE/dist/forcecalls"; APP_SRC="$HERE/dist/Forcecalls.app"
else
    echo "✗ no Swift toolchain (xcode-select --install) and no prebuilt dist/."; exit 1
fi
[ -x "$CLI_SRC" ] || { echo "✗ no CLI binary at $CLI_SRC"; exit 1; }
[ -d "$APP_SRC" ] || { echo "✗ no app bundle at $APP_SRC"; exit 1; }

# ── deploy ───────────────────────────────────────────────────────────────────────────────────────
echo "▸ deploying binary, app, and CLI"
install -d -m 755 -o root -g wheel /usr/local/libexec
install -m 0755 -o root -g wheel "$CLI_SRC" "$BIN"
cat > /usr/local/bin/forcecalls <<'WRAP'
#!/bin/bash
exec /usr/local/libexec/forcecalls "$@"
WRAP
chmod 755 /usr/local/bin/forcecalls
chown root:wheel /usr/local/bin/forcecalls

# Never leave a user-owned duplicate in ~/Applications (it could be launched instead, and would only
# be spared by demonlock under the stricter rule). go-w so the bundle passes demonlock's owner check.
rm -rf "$(eval echo "~$USER_NAME")/Applications/Forcecalls.app" /Applications/Forcecalls.app
cp -R "$APP_SRC" /Applications/Forcecalls.app
chown -R root:wheel /Applications/Forcecalls.app
chmod -R go-w /Applications/Forcecalls.app
xattr -dr com.apple.quarantine /Applications/Forcecalls.app 2>/dev/null || true

# ── layout ───────────────────────────────────────────────────────────────────────────────────────
echo "▸ seeding $SUPPORT"
mkdir -p "$SUPPORT/logs" "$SUPPORT/inbox"
[ -f "$SUPPORT/calls.json" ] || printf '[]' > "$SUPPORT/calls.json"
[ -f "$SUPPORT/state.json" ] || printf '{}' > "$SUPPORT/state.json"
# Only the per-machine key is seeded; behavioural defaults live in Settings.swift and are decoded
# leniently, so changing a default there actually takes effect instead of being shadowed here.
cat > "$SUPPORT/settings.json" <<EOF
{
  "enforcedUser" : "$USER_NAME"
}
EOF

# ── credentials (stdin, never committed) ─────────────────────────────────────────────────────────
# Collected once here and written root-owned 0600. You can't read them back afterwards, so a forced
# call can't be quietly defanged by editing the keys out — and nothing secret lives in the repo.
if [ -f "$SUPPORT/creds.json" ] && [ "${1:-}" != "--reset-creds" ]; then
    echo "▸ keeping existing credentials (re-run with --reset-creds to replace them)"
else
    echo "▸ SignalWire credentials — from your Space's API tab. The token is not echoed."
    read -r -p "  Space (e.g. minh.signalwire.com): " SW_SPACE
    read -r -p "  Project ID: " SW_PROJECT
    read -r -s -p "  API token: " SW_TOKEN; echo
    read -r -p "  Caller ID the other person sees (+E.164): " SW_CALLERID
    read -r -p "  Your SIP endpoint (e.g. sip:me@minh.sip.signalwire.com): " SW_ENDPOINT
    for v in SW_SPACE SW_PROJECT SW_TOKEN SW_CALLERID SW_ENDPOINT; do
        [ -n "${!v}" ] || { echo "✗ $v can't be empty"; exit 1; }
    done
    umask 077
    cat > "$SUPPORT/creds.json" <<EOF
{
  "space"     : "$SW_SPACE",
  "projectId" : "$SW_PROJECT",
  "apiToken"  : "$SW_TOKEN",
  "callerId"  : "$SW_CALLERID",
  "endpoint"  : "$SW_ENDPOINT"
}
EOF
    umask 022
fi

# Root owns everything except the inbox — that asymmetry IS the design. calls.json is root-owned so
# you can't hand-edit a forced call away; the inbox is yours so add/remove/abort need no sudo.
chown -R root:wheel "$SUPPORT"
chmod 755 "$SUPPORT" "$SUPPORT/logs"
chmod 644 "$SUPPORT/settings.json" "$SUPPORT/calls.json" "$SUPPORT/state.json"
chmod 600 "$SUPPORT/creds.json"
chown "$USER_NAME" "$SUPPORT/inbox"
chmod 700 "$SUPPORT/inbox"

# ── launchd ──────────────────────────────────────────────────────────────────────────────────────
echo "▸ installing + loading the daemon and agent"
cp install/com.forcecalls.daemon.plist /Library/LaunchDaemons/
cp install/com.forcecalls.agent.plist  /Library/LaunchAgents/
chown root:wheel /Library/LaunchDaemons/com.forcecalls.daemon.plist /Library/LaunchAgents/com.forcecalls.agent.plist
chmod 644        /Library/LaunchDaemons/com.forcecalls.daemon.plist /Library/LaunchAgents/com.forcecalls.agent.plist

# Point the agent log at the user's own Library/Logs, not world-writable /tmp (another local account
# could pre-create the path as a symlink).
USER_HOME="$(eval echo "~$USER_NAME")"
mkdir -p "$USER_HOME/Library/Logs" 2>/dev/null || true
chown "$USER_NAME" "$USER_HOME/Library/Logs" 2>/dev/null || true
/usr/bin/sed -i '' "s#/tmp/forcecalls-agent.log#$USER_HOME/Library/Logs/forcecalls-agent.log#g" \
    /Library/LaunchAgents/com.forcecalls.agent.plist

launchctl bootout system/com.forcecalls.daemon 2>/dev/null || true
launchctl bootout "gui/$USER_UID/com.forcecalls.agent" 2>/dev/null || true
sleep 1
launchctl bootstrap system /Library/LaunchDaemons/com.forcecalls.daemon.plist 2>/dev/null \
    || launchctl kickstart -k system/com.forcecalls.daemon 2>/dev/null || true
launchctl bootstrap "gui/$USER_UID" /Library/LaunchAgents/com.forcecalls.agent.plist 2>/dev/null \
    || launchctl kickstart -k "gui/$USER_UID/com.forcecalls.agent" 2>/dev/null || true

# A demonlock lockout force-closes .regular apps — which the agent becomes for the duration of a
# call. Spare it, or a lockout at 8:45 PM would kill the window mid-conversation.
DL=/Applications/Demonlock.app/Contents/MacOS/demonlock
if [ -x "$DL" ]; then
  "$DL" safe-apps register com.forcecalls \
    || echo "  ⚠️  demonlock register failed — spare it manually: sudo demonlock safe-apps register com.forcecalls"
else
  echo "  (demonlock not installed — if you add it later:  sudo demonlock safe-apps register com.forcecalls)"
fi

echo
echo "✓ installed. Everything below is user-runnable — NO sudo:"
echo "    forcecalls add --name mom --destination +15559998888 --schedule *2045"
echo "    forcecalls show"
echo
echo "Removal is delay-gated (default 12h): 'forcecalls remove mom' queues it, 'forcecalls abort'"
echo "cancels. Only install/uninstall need sudo — that's what makes a forced call stick."
echo
echo "The endpoint (baresip) is separate — see endpoint/INSTALL.md. Until it's registered, calls will"
echo "reach the other person and then fail to bridge to you."
