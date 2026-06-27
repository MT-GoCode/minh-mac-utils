#!/bin/bash
# Install wtalk: freeze+sign (as you), deploy ROOT-OWNED to /Applications (sealed,
# unmodifiable without sudo — which is what lets demonlock safely whitelist it), install the
# CLI wrapper, seed ~/.wtalk DATA templates (owned by you), load the LaunchAgent.
# Run:  sudo ./install/install.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./install/install.sh"; exit 1; }
: "${SUDO_USER:?must be run via sudo (need SUDO_USER for the build keychain + user data)}"
USER_NAME="$SUDO_USER"
USER_UID="$(id -u "$USER_NAME")"
USER_HOME="$(/usr/bin/dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')"
[ -n "$USER_HOME" ] || USER_HOME="/Users/$USER_NAME"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="wtalk.app"
DEST="/Applications/$APP"
APP_EXE="$DEST/Contents/MacOS/wtalk"
DATA="$USER_HOME/.wtalk"
cd "$HERE"

# --- choose the bundle to deploy (same signing ladder as demonlock/serialize) ---------------
# Build fresh as the user if a Nuitka toolchain + venv are present; else deploy the prebuilt,
# already-signed dist/wtalk.app. Don't ad-hoc-resign over a Developer-ID-signed dist copy.
HAVE_DEVID="$(sudo -u "$USER_NAME" security find-identity -p codesigning -v 2>/dev/null \
              | grep -c 'Developer ID Application' || true)"
if [ -d "$HERE/dist/$APP" ] && [ "${HAVE_DEVID:-0}" -eq 0 ] && [ ! -d "$HERE/.venv" ]; then
    echo "▸ no Developer ID cert + no venv — deploying prebuilt dist/$APP (no re-sign)"
    SRC="$HERE/dist/$APP"
elif [ -d "$HERE/.venv" ]; then
    echo "▸ freezing + signing as $USER_NAME (Nuitka — first compile is slow)"
    sudo -u "$USER_NAME" bash install/build.sh
    SRC="$HERE/$APP"
elif [ -d "$HERE/dist/$APP" ]; then
    echo "▸ deploying prebuilt dist/$APP"
    SRC="$HERE/dist/$APP"
else
    echo "✗ no .venv to build from and no prebuilt dist/$APP."
    echo "  Run ./setup.sh first (creates the venv + deps), then re-run sudo ./install.sh."
    exit 1
fi
[ -d "$SRC" ] || { echo "✗ no app bundle to deploy"; exit 1; }

# --- stop anything already running, nuke any old user-owned install ------------------------
echo "▸ stopping any running wtalk + clearing old-era remnants"
sudo -u "$USER_NAME" launchctl bootout "gui/$USER_UID/com.wtalk.agent" 2>/dev/null || true
pkill -x wtalk 2>/dev/null || true
rm -f "$USER_HOME/Library/LaunchAgents/com.wtalk.agent.plist"   # pre-sudo era (user-owned plist)
rm -f "$USER_HOME/.local/bin/wtalk"                             # pre-sudo era PATH symlink (else `wtalk` runs the old path)
rm -rf "$HERE/wtalk.app.old"

echo "▸ deploying ROOT-OWNED to $DEST"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
chown -R root:wheel "$DEST"        # root-owned ⇒ unmodifiable without sudo (the seal)
chmod -R go-w "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
/usr/bin/mdimport "$DEST" >/dev/null 2>&1 || true

echo "▸ installing /usr/local/bin/wtalk wrapper"
mkdir -p /usr/local/bin
cat > /usr/local/bin/wtalk <<EOF
#!/bin/bash
# Frozen wtalk dispatches its runtime subcommands (toggle/status/cancel/verbatim/history/
# restart) from argv — Karabiner binds F5 → \`wtalk toggle\`, which lands here.
exec "$APP_EXE" "\$@"
EOF
chmod 755 /usr/local/bin/wtalk
chown root:wheel /usr/local/bin/wtalk

# --- seed ~/.wtalk DATA (user-owned; editing it can't redirect the sealed binary) ----------
echo "▸ seeding $DATA (templates only if absent; never overwrites your edits/keys)"
sudo -u "$USER_NAME" mkdir -p "$DATA/prompts"
# .env: API keys live ONLY here, never in the bundle.
if [ ! -f "$DATA/.env" ]; then
    sudo -u "$USER_NAME" tee "$DATA/.env" >/dev/null <<'EOF'
# Required: Gemini cleanup (https://aistudio.google.com/apikey)
GEMINI_API_KEY=
# Optional fallback (https://console.groq.com/keys). A 2nd key doubles rate headroom.
GROQ_API_KEY=
GROQ_API_KEY_2=
EOF
    chmod 600 "$DATA/.env"; chown "$USER_NAME" "$DATA/.env"
fi
# config.txt + prompts: seed the bundled defaults so they're editable WITHOUT touching the
# sealed bundle. Skips any file you've already customized.
[ -f "$DATA/config.txt" ] || sudo -u "$USER_NAME" cp "$HERE/config.txt" "$DATA/config.txt"
for p in cleanup_system.txt user.txt; do
    [ -f "$DATA/prompts/$p" ] || sudo -u "$USER_NAME" cp "$HERE/prompts/$p" "$DATA/prompts/$p"
done
chown -R "$USER_NAME" "$DATA"

# --- prime the two TCC prompts (best-effort; macOS often defers Mic to first real use) ------
echo "▸ requesting permissions (approve BOTH dialogs as 'wtalk' if they appear)…"
sudo -u "$USER_NAME" "$APP_EXE" --prime-perms >/dev/null 2>&1 || true

# --- install + bootstrap the LaunchAgent (root-owned plist in /Library/LaunchAgents) -------
echo "▸ installing LaunchAgent com.wtalk.agent"
FF="$(sudo -u "$USER_NAME" bash -lc 'command -v ffmpeg' 2>/dev/null || true)"
KARABIN="/Library/Application Support/org.pqrs/Karabiner-Elements/bin"
AGENT_PATH="$(printf '%s' \
  "${FF:+$(dirname "$FF"):}$USER_HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$KARABIN:/usr/bin:/bin:/usr/sbin:/sbin")"
PLIST="/Library/LaunchAgents/com.wtalk.agent.plist"
sed -e "s#__APP_EXE__#$APP_EXE#g" \
    -e "s#__HOME__#$USER_HOME#g" \
    -e "s#__PATH__#$AGENT_PATH#g" \
    install/com.wtalk.agent.plist > "$PLIST"
chown root:wheel "$PLIST"; chmod 644 "$PLIST"

echo "▸ (re)loading the agent into gui/$USER_UID"
sudo -u "$USER_NAME" launchctl bootout "gui/$USER_UID/com.wtalk.agent" 2>/dev/null || true
sleep 1
sudo -u "$USER_NAME" launchctl bootstrap "gui/$USER_UID" "$PLIST" 2>/dev/null \
    || sudo -u "$USER_NAME" launchctl kickstart -k "gui/$USER_UID/com.wtalk.agent" 2>/dev/null || true

echo
echo "✓ installed $DEST  (root:wheel, sealed — demonlock can now safely spare it)"
echo "  Next steps:"
echo "    1. Add your Gemini key:   \$EDITOR $DATA/.env   (GEMINI_API_KEY=…), then:  wtalk restart"
echo "       (https://aistudio.google.com/apikey — without it, cleanup pastes the RAW transcript)"
echo "    2. Grant perms in System Settings ▸ Privacy & Security (both show as 'wtalk'):"
echo "         • Microphone    — often only prompts on your FIRST dictation; approve it then"
echo "         • Accessibility — needed to paste at the cursor"
echo "    3. Bind F5 in Karabiner-Elements (Complex Modifications) to run:"
echo "         /usr/local/bin/wtalk toggle"
echo "    4. Check it:   wtalk status      (first launch downloads the Parakeet model — ~minute)"
echo
echo "  Optional: brew install nowplaying-cli  (auto-pause media while dictating)"
