#!/bin/bash
# Install wtalk: freeze+sign (as you), deploy ROOT-OWNED to /Applications (sealed — what lets demonlock
# whitelist it), CLI wrapper, seed ~/.wtalk DATA templates (yours), load the LaunchAgent as you.
# Run:  sudo ./install.sh [--prebuilt] [--no-prime-perms]
#   --prebuilt        deploy dist/wtalk.app as-is (no PyInstaller, no keychain / smartcard PIN)
#   --no-prime-perms  skip firing the Mic/Accessibility TCC prompts (install-all passes this on a
#                     reinstall; --prime-perms blocks on a pending dialog when there is no GUI)
set -uo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$APP_DIR/../scripts/install-lib.sh"
dl_require_root
PRIME=1
for a in "$@"; do case "$a" in --prebuilt) export PREBUILT=1;; --no-prime-perms) PRIME=0;; esac; done
cd "$APP_DIR"

APP_TYPE=gui-app
APP_NAME=wtalk
BUNDLE=wtalk.app
BUNDLE_ID=com.minh.wtalk
TEAM_ID=BULCQM9J2V
CLI=wtalk
CLI_WRAPPER=yes
SPARED=yes
STOP_FIRST=yes                       # a running wtalk must be gone before the bundle is replaced
PROC_NAME=wtalk
AGENT_LABEL=com.minh.wtalk.agent
USER_NAME="$(dl_user)"; USER_UID="$(dl_user_uid)"; USER_HOME="$(dl_user_home)"
APP_EXE="/Applications/$BUNDLE/Contents/MacOS/wtalk"
DATA="$USER_HOME/.wtalk"

# Build needs the venv (./setup.sh). With --prebuilt, dl_pick_bundle deploys dist/ without building.
provide_bundle() {
  if [ "${PREBUILT:-0}" != 1 ] && [ ! -d "$APP_DIR/.venv" ]; then
    echo "✗ no .venv to build from — run ./setup.sh first (creates the venv + deps), or use --prebuilt." >&2; return 1
  fi
  dl_pick_bundle "$APP_DIR/wtalk.app" "$APP_DIR/install/build.sh" "$APP_DIR/dist/wtalk.app"
}

post_install() {
  # pre-sudo-era remnants
  rm -f "$USER_HOME/Library/LaunchAgents/com.minh.wtalk.agent.plist" "$USER_HOME/.local/bin/wtalk"
  rm -rf "$APP_DIR/wtalk.app.old"
  /usr/bin/mdimport "/Applications/$BUNDLE" >/dev/null 2>&1 || true
  # Back-compat symlink: existing Karabiner rules / PATH refs call ~/.local/bin/wtalk.
  sudo -u "$USER_NAME" mkdir -p "$USER_HOME/.local/bin"
  sudo -u "$USER_NAME" ln -sf /usr/local/bin/wtalk "$USER_HOME/.local/bin/wtalk"

  echo "▸ seeding $DATA (templates only if absent; never overwrites your edits/keys)"
  sudo -u "$USER_NAME" mkdir -p "$DATA/prompts"
  if [ ! -f "$DATA/.env" ]; then
    sudo -u "$USER_NAME" tee "$DATA/.env" >/dev/null <<'ENV'
# Required: Gemini cleanup (https://aistudio.google.com/apikey)
GEMINI_API_KEY=
# Optional fallback (https://console.groq.com/keys). A 2nd key doubles rate headroom.
GROQ_API_KEY=
GROQ_API_KEY_2=
ENV
    chmod 600 "$DATA/.env"; chown "$USER_NAME" "$DATA/.env"
  fi
  [ -f "$DATA/config.txt" ] || sudo -u "$USER_NAME" cp "$APP_DIR/config.txt" "$DATA/config.txt"
  local p
  for p in cleanup_system.txt user.txt; do
    [ -f "$DATA/prompts/$p" ] || sudo -u "$USER_NAME" cp "$APP_DIR/prompts/$p" "$DATA/prompts/$p"
  done
  chown -R "$USER_NAME" "$DATA"

  if [ "$PRIME" = 1 ]; then
    echo "▸ requesting permissions (approve BOTH dialogs as 'wtalk' if they appear)…"
    sudo -u "$USER_NAME" "$APP_EXE" --prime-perms >/dev/null 2>&1 || true
  fi

  echo "▸ installing LaunchAgent com.minh.wtalk.agent"
  # ffmpeg/Karabiner PATH discovery is wtalk-specific and stays here; the lib only substitutes.
  local ff karabin agent_path
  ff="$(sudo -u "$USER_NAME" bash -lc 'command -v ffmpeg' 2>/dev/null || true)"
  karabin="/Library/Application Support/org.pqrs/Karabiner-Elements/bin"
  agent_path="${ff:+$(dirname "$ff"):}$USER_HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$karabin:/usr/bin:/bin:/usr/sbin:/sbin"
  dl_install_launchd "$APP_DIR/install/com.minh.wtalk.agent.plist" agent --as-user \
    --sed "__APP_EXE__=$APP_EXE" --sed "__HOME__=$USER_HOME" --sed "__PATH__=$agent_path" || return 1
}

dl_run_manifest || exit 1

echo
echo "✓ installed /Applications/$BUNDLE  (root:wheel, sealed, registered as a demonlock spare)."
echo "  Verify it survives a lockout:  demonlock test-lockout"
echo "  Next steps:"
echo "    1. Add your Gemini key:   \$EDITOR $DATA/.env   (GEMINI_API_KEY=…), then:  wtalk restart"
echo "    2. Grant perms in System Settings ▸ Privacy & Security (both show as 'wtalk'):"
echo "         • Microphone    — often only prompts on your FIRST dictation; approve it then"
echo "         • Accessibility — needed to paste at the cursor"
echo "    3. Bind F5 in Karabiner-Elements (Complex Modifications) to run:  /usr/local/bin/wtalk toggle"
echo "    4. Check it:   wtalk status      (first launch downloads the Parakeet model — ~minute)"
echo
echo "  Optional: brew install nowplaying-cli  (auto-pause media while dictating)"
