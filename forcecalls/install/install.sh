#!/bin/bash
# Install forcecalls: build + sign (as you), deploy root-owned, collect SignalWire creds, load the
# root daemon and the GUI agent.
# Run:  sudo ./install.sh [--reset-creds]
set -euo pipefail

# Bespoke installer (like demonlock / wtalk / nextdns-sidecar): the stdin credential prompt, the
# root daemon + GUI agent pair, and the root-owned-except-the-inbox layout don't fit the gui-app
# manifest. Still sources the shared lib for the common primitives — notably dl_register_spare,
# since demonlock ships no base spare list and each app registers itself at install.
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$APP_DIR/../scripts/install-lib.sh"
dl_require_root

BUNDLE_ID=com.minh.forcecalls
TEAM_ID=BULCQM9J2V
USER_NAME="$SUDO_USER"
USER_UID="$(id -u "$USER_NAME")"
HERE="$APP_DIR"
SUPPORT="/Library/Application Support/Forcecalls"
BIN=/usr/local/libexec/forcecalls
cd "$HERE"

# ── preflight ────────────────────────────────────────────────────────────────────────────────────
# Everything this install needs, checked up front. A missing prerequisite discovered halfway through
# leaves a half-installed system, which is exactly the failure this script already had once.
MISSING_TOOLS=""
sudo -u "$USER_NAME" command -v brew >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS homebrew"
command -v nc >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS netcat(nc)"
if ! xcode-select -p >/dev/null 2>&1 && [ ! -d "$APP_DIR/dist/Forcecalls.app" ]; then
    MISSING_TOOLS="$MISSING_TOOLS xcode-command-line-tools"
fi
if [ -n "$MISSING_TOOLS" ]; then
    echo "✗ missing prerequisite(s):$MISSING_TOOLS"
    echo "  Homebrew:  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    echo "  Xcode CLT: xcode-select --install"
    echo "  nothing was installed."
    exit 1
fi
if sudo -u "$USER_NAME" command -v baresip >/dev/null 2>&1; then
    dl_ok "baresip present"
else
    echo "  · baresip not installed yet — the endpoint step will brew-install it"
fi

# ── credentials (collected BEFORE anything is written) ──────────────────────────────────────────
# Gathered up front, on purpose: a prompt that aborts must leave NO half-seeded root-owned directory
# behind. Falls back to env vars so a non-interactive run (an agent, a script, CI) works instead of
# dying on a read with no TTY.
NEED_CREDS=yes
if [ -f "$SUPPORT/creds.json" ] && [ "${1:-}" != "--reset-creds" ]; then NEED_CREDS=no; fi
if [ "$NEED_CREDS" = yes ]; then
    if [ -t 0 ]; then
        echo "▸ SignalWire credentials — from your Space's API tab. The token is not echoed."
        [ -n "${SW_SPACE:-}"    ] || read -r    -p "  Space (e.g. minh.signalwire.com): " SW_SPACE
        [ -n "${SW_PROJECT:-}"  ] || read -r    -p "  Project ID: " SW_PROJECT
        [ -n "${SW_TOKEN:-}"    ] || { read -r -s -p "  API token: " SW_TOKEN; echo; }
        [ -n "${SW_CALLERID:-}" ] || read -r    -p "  Caller ID the other person sees (+E.164): " SW_CALLERID
        [ -n "${SW_ENDPOINT:-}" ] || read -r    -p "  Your SIP endpoint (copy from the New SIP Credential dialog): " SW_ENDPOINT
        [ -n "${SIP_PASS:-}"    ] || { read -r -s -p "  Password for that SIP credential: " SIP_PASS; echo; }
    else
        echo "▸ non-interactive install — reading credentials from the environment"
    fi
    MISSING=""
    for v in SW_SPACE SW_PROJECT SW_TOKEN SW_CALLERID SW_ENDPOINT SIP_PASS; do
        [ -n "${!v:-}" ] || MISSING="$MISSING $v"
    done
    if [ -n "$MISSING" ]; then
        echo "✗ missing credential(s):$MISSING"
        echo "  run this from a terminal to be prompted, or pre-set them:"
        echo "    sudo SW_SPACE=… SW_PROJECT=… SW_TOKEN=… SW_CALLERID=… SW_ENDPOINT=… SIP_PASS=… ./install.sh"
        echo "  nothing was installed."
        exit 1
    fi
else
    echo "▸ keeping existing credentials (re-run with --reset-creds to replace them)"
    if [ -z "${SIP_PASS:-}" ]; then
        if [ -t 0 ]; then read -r -s -p "  Password for your SIP credential (for the endpoint): " SIP_PASS; echo
        else echo "✗ set SIP_PASS= — the endpoint needs it even when the API creds are unchanged."; exit 1; fi
    fi
fi

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

# Root-owned 0600, and you can't read it back — so a forced call can't be quietly defanged by
# editing the keys out, and nothing secret ever lives in the repo.
if [ "$NEED_CREDS" = yes ]; then
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
cp install/com.minh.forcecalls.daemon.plist /Library/LaunchDaemons/
cp install/com.minh.forcecalls.agent.plist  /Library/LaunchAgents/
chown root:wheel /Library/LaunchDaemons/com.minh.forcecalls.daemon.plist /Library/LaunchAgents/com.minh.forcecalls.agent.plist
chmod 644        /Library/LaunchDaemons/com.minh.forcecalls.daemon.plist /Library/LaunchAgents/com.minh.forcecalls.agent.plist

# Point the agent log at the user's own Library/Logs, not world-writable /tmp (another local account
# could pre-create the path as a symlink).
USER_HOME="$(eval echo "~$USER_NAME")"
mkdir -p "$USER_HOME/Library/Logs" 2>/dev/null || true
chown "$USER_NAME" "$USER_HOME/Library/Logs" 2>/dev/null || true
/usr/bin/sed -i '' "s#/tmp/forcecalls-agent.log#$USER_HOME/Library/Logs/forcecalls-agent.log#g" \
    /Library/LaunchAgents/com.minh.forcecalls.agent.plist

launchctl bootout system/com.minh.forcecalls.daemon 2>/dev/null || true
launchctl bootout "gui/$USER_UID/com.minh.forcecalls.agent" 2>/dev/null || true
sleep 1
launchctl bootstrap system /Library/LaunchDaemons/com.minh.forcecalls.daemon.plist 2>/dev/null \
    || launchctl kickstart -k system/com.minh.forcecalls.daemon 2>/dev/null || true
launchctl bootstrap "gui/$USER_UID" /Library/LaunchAgents/com.minh.forcecalls.agent.plist 2>/dev/null \
    || launchctl kickstart -k "gui/$USER_UID/com.minh.forcecalls.agent" 2>/dev/null || true

# A demonlock lockout force-closes .regular apps — and the agent becomes .regular for the duration
# of a call. Spare it, or a lockout at 8:45 PM would kill the window mid-conversation. Root-owned in
# /Applications, so this takes the plain Regime A path (bundle only, no --no-root-ownership).
dl_register_spare forcecalls "$BUNDLE_ID" "$TEAM_ID" \
    || dl_warn "spare registration failed — do it by hand: sudo demonlock safe-apps register $BUNDLE_ID"

# ── endpoint ─────────────────────────────────────────────────────────────────────────────────────
# Not optional: without it a forced call reaches the other person and has nothing to bridge to. It
# reads the username and domain back out of the creds.json written above.
echo
echo "▸ installing the endpoint (baresip)"
SIP_PASS="$SIP_PASS" bash "$APP_DIR/endpoint/install.sh"

echo
echo "✓ installed. Everything below is user-runnable — NO sudo:"
echo "    forcecalls add --name mom --destination +15559998888 --schedule *2045"
echo "    forcecalls show"
echo
echo "Removal is delay-gated (default 12h): 'forcecalls remove mom' queues it, 'forcecalls abort'"
echo "cancels. Only install/uninstall need sudo — that's what makes a forced call stick."
