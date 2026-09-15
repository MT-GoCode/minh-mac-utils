#!/bin/bash
# install-all.sh — set up a Mac with every minh-mac-utils tool in ONE run, from a normal terminal.
#
#   ./install-all.sh                 everything, in order
#   ./install-all.sh --only <tool>   phases 0–2, then just that tool  (demonlock|blockrem|multistreamviewer|
#                                    stayup|wtalk|nextdns-sidecar|remote-agent-connector|browser-blitz|paseo)
#   ./install-all.sh --from <phase>  resume at a phase: preflight|secrets|identity|root|user|verify|checklist
#   ./install-all.sh --no-secrets    skip the secrets prompts (only valid when every target is already filled)
#
# Phases: 0 preflight → 1 secrets (one tty pass) → 2 identity (one keychain prompt) → 3 root installs
# (ONE sudo shell: demonlock first, rac last) → 4 user installs → 5 verify (root-free) → 6 human checklist.
# Stops at the first failure. Every installer is idempotent, so re-running is safe.
set -uo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"

ONLY=""; FROM="preflight"; NOSECRETS=0
while [ $# -gt 0 ]; do case "$1" in
  --only) ONLY="$2"; shift 2;; --from) FROM="$2"; shift 2;; --no-secrets) NOSECRETS=1; shift;;
  -h|--help) sed -n 2,12p "$0"; exit 0;; *) echo "unknown arg: $1"; exit 1;; esac; done

ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠️  $*" >&2; }
die()  { echo "✗ $*" >&2; exit 1; }
phase_index() { case "$1" in preflight) echo 0;; secrets) echo 1;; identity) echo 2;; root) echo 3;; user) echo 4;; verify) echo 5;; checklist) echo 6;; *) echo 99;; esac; }
FROM_I="$(phase_index "$FROM")"; [ "$FROM_I" != 99 ] || die "unknown --from phase: $FROM"
want() { [ "$(phase_index "$1")" -ge "$FROM_I" ]; }
tool_wanted() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

ME="$(id -un)"; UID_ME="$(id -u)"; HOME_ME="$HOME"
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
CREDFILE=""; cleanup() { [ -n "$CREDFILE" ] && rm -f "$CREDFILE"; }; trap cleanup EXIT
SSH_SESSION=0; [ -n "${SSH_CONNECTION:-}" ] && SSH_SESSION=1
WTALK_PREEXISTED=0; [ -d /Applications/wtalk.app ] && WTALK_PREEXISTED=1
MOBILECONFIG=""

# ---------------------------------------------------------------- 0 preflight
phase_preflight() {
  echo "▸ phase 0 — preflight"
  local missing=() fixit=()
  [ "$ME" != root ] || die "run as your normal user, not root (the script calls sudo itself)"
  [ -t 0 ] && [ -t 1 ] || die "needs a real terminal (not rac exec / cron / a pipe) — phase 1 prompts for secrets"
  case "$REPO" in /tmp/*|/private/tmp/*|/private/var/folders/*|*'#'*) die "clone the repo somewhere stable (e.g. ~/code/minh-mac-utils) — LaunchAgents bake this path in";; esac
  # CLT FIRST: /usr/bin/git, python3, swift are stubs that pop the CLT installer GUI when it's absent.
  if ! xcode-select -p >/dev/null 2>&1; then missing+=("Xcode Command Line Tools"); fixit+=("xcode-select --install     # opens a GUI dialog; click Install, wait, re-run"); fi
  command -v brew >/dev/null 2>&1 || { missing+=("Homebrew"); fixit+=('/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'); }
  local pkg; for pkg in ffmpeg jq node; do command -v "$pkg" >/dev/null 2>&1 || { missing+=("$pkg"); fixit+=("brew install $pkg"); }; done
  command -v uv >/dev/null 2>&1 || { missing+=("uv"); fixit+=("curl -LsSf https://astral.sh/uv/install.sh | sh"); }
  [ -d "/Applications/Karabiner-Elements.app" ] || { missing+=("Karabiner-Elements"); fixit+=("brew install --cask karabiner-elements   # then approve its driver extension in System Settings"); }
  [ -d "/Applications/Paseo.app" ] || warn "Paseo.app not installed — the paseo daemon step will be skipped"
  # NextDNS profile: newest single match (two matches would be 'unknown argument' to the sidecar).
  MOBILECONFIG="$(ls -t "$HOME"/Downloads/NextDNS-*.mobileconfig 2>/dev/null | head -1 || true)"
  if [ -z "$MOBILECONFIG" ] && [ ! -f "/Library/Managed Preferences/com.apple.dnsSettings.managed.plist" ]; then
    missing+=("NextDNS .mobileconfig"); fixit+=("# log in at https://apple.nextdns.io and download your profile to ~/Downloads (a browser step)")
  fi
  # console session must be this user (gui-domain LaunchAgents load only into an Aqua session)
  who | grep -q "^$ME .*console" || warn "no console session for $ME — gui LaunchAgents will fail to load (log in locally, or expect verify failures)"
  [ "$SSH_SESSION" = 1 ] && warn "SSH session: remote-agent-connector is SKIPPED (its reinstall kills this tunnel) — run '--only remote-agent-connector' from a local terminal; consider tmux for the rest"
  # admin: sudo must actually be possible
  if ! dseditgroup -o checkmember -m "$ME" admin >/dev/null 2>&1; then
    die "$ME is not in the admin group. If demonlock is installed: demonlock admin-release-valve request \"4h\" and re-run once granted."
  fi
  if [ -x /usr/local/bin/demonlock ]; then
    local rv; rv="$(demonlock admin-release-valve status 2>/dev/null | sed -n 2p || true)"
    if printf '%s' "$rv" | grep -q GRANTED; then
      local mins; mins="$(printf '%s' "$rv" | sed -n 's/.*held, \([0-9]*\)h\([0-9]*\)m.*/\1 \2/p' | awk '{print $1*60+$2}')"
      [ "${mins:-0}" -ge 30 ] || die "release-valve grant has ${mins:-?} min left — need ≥30. Run: sudo demonlock admin-release-valve i-still-need-sudo \"for 1h\""
      ok "release-valve grant: ${mins}m left"
    fi
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    echo; echo "✗ missing: ${missing[*]}"; echo; echo "  Fix-it (run these, then re-run ./install-all.sh):"
    printf '    %s\n' "${fixit[@]}"; exit 1
  fi
  ok "preflight clean"
}

# ---------------------------------------------------------------- 1 secrets
phase_secrets() {
  echo "▸ phase 1 — secrets (one pass; Enter to skip any you'll add later)"
  [ "$NOSECRETS" = 1 ] && { ok "--no-secrets: skipping"; return; }
  if tool_wanted nextdns-sidecar; then
    printf "NextDNS Profile ID (blank = keep existing/skip): "; read -r p
    if [ -n "$p" ]; then
      printf "NextDNS API key (hidden): "; read -rs k; echo
      CREDFILE="$(mktemp "${TMPDIR:-/tmp}/nextdns-cred.XXXXXX")"; chmod 600 "$CREDFILE"
      printf 'PROFILE=%s\nAPI_KEY=%s\n' "$p" "$k" > "$CREDFILE"; unset p k
      ok "NextDNS credentials staged (deleted on exit)"
    fi
  fi
  if tool_wanted wtalk && ! grep -qs '^GEMINI_API_KEY=.\+' "$HOME/.wtalk/.env"; then
    printf "Gemini API key for wtalk (hidden; blank = later): "; read -rs g; echo
    if [ -n "$g" ]; then
      mkdir -p "$HOME/.wtalk"; umask 077
      [ -f "$HOME/.wtalk/.env" ] || printf '# Required: Gemini cleanup (https://aistudio.google.com/apikey)\nGEMINI_API_KEY=\n# Optional fallback (https://console.groq.com/keys). A 2nd key doubles rate headroom.\nGROQ_API_KEY=\nGROQ_API_KEY_2=\n' > "$HOME/.wtalk/.env"
      sed -i '' "s|^GEMINI_API_KEY=.*|GEMINI_API_KEY=$g|" "$HOME/.wtalk/.env"; chmod 600 "$HOME/.wtalk/.env"; umask 022; unset g
      ok "~/.wtalk/.env"
    fi
  fi
  if tool_wanted remote-agent-connector && [ "$SSH_SESSION" = 0 ] && ! grep -qs '^MIDDLEMAN=.\+' "$HOME/.remote-agent-connector/config"; then
    printf "rac MIDDLEMAN host (blank = later): "; read -r mm
    if [ -n "$mm" ]; then
      printf "rac MACHINE_NAME [%s]: " "$(hostname -s)"; read -r mn; mn="${mn:-$(hostname -s)}"
      mkdir -p "$HOME/.remote-agent-connector"
      printf 'MIDDLEMAN="%s"\nMACHINE_NAME="%s"\n' "$mm" "$mn" > "$HOME/.remote-agent-connector/config"
      ok "~/.remote-agent-connector/config"
    fi
  fi
}

# ---------------------------------------------------------------- 2 identity
phase_identity() {
  echo "▸ phase 2 — signing identity (one keychain prompt for every build)"
  CODESIGN_IDENTITY="$(bash "$REPO/signing-ladder.sh")" || CODESIGN_IDENTITY="-"
  export CODESIGN_IDENTITY
  if [ "$SSH_SESSION" = 1 ] && printf '%s' "$CODESIGN_IDENTITY" | grep -q "Developer ID"; then
    warn "Developer ID over SSH: if the key needs a smartcard PIN, builds will hang — run from a local terminal"
  fi
  ok "CODESIGN_IDENTITY=$CODESIGN_IDENTITY"
}

# ---------------------------------------------------------------- 3+4 root (ONE sudo shell)
phase_root_and_user() {
  echo "▸ phase 3/4 — installs (one sudo session; password once)"
  sudo -v || die "sudo failed"
  local wtalk_flag=""; [ "$WTALK_PREEXISTED" = 1 ] && wtalk_flag="--no-prime-perms"
  local sc_flags=(); [ -n "$MOBILECONFIG" ] && sc_flags+=(--profile-src "$MOBILECONFIG"); [ -n "$CREDFILE" ] && sc_flags+=(--credentials-file "$CREDFILE")
  local skip_rac="$SSH_SESSION"
  # Everything below runs inside ONE root shell: the sudo timestamp can't expire during wtalk's long
  # PyInstaller build, and a release-valve revoke mid-run can't strand later steps. SUDO_USER is inherited
  # by every installer; CODESIGN_IDENTITY is passed explicitly (sudo's env_reset would strip it).
  # The root script goes through a temp FILE, not `bash -s` on stdin — installers spawn children that
  # would otherwise eat the rest of the script off the shared stdin.
  local rootsh; rootsh="$(mktemp "${TMPDIR:-/tmp}/install-all-root.XXXXXX")"
  cat > "$rootsh" <<'ROOT'
set -uo pipefail
cd "$REPO"; export PATH="/opt/homebrew/bin:/Users/$SUDO_USER/.local/bin:$PATH"
tool_wanted() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
run() { echo; echo "━━ $1"; shift; "$@" || { echo "✗ $1 failed — stopping (fix, then: ./install-all.sh --only <tool> or --from root)"; exit 1; }; }
if [ "$FROM_I" -le 3 ]; then
  tool_wanted demonlock         && run "demonlock"         ./demonlock/install.sh
  tool_wanted blockrem          && run "blockrem"          ./blockrem/install.sh
  tool_wanted multistreamviewer && run "multistreamviewer" ./multistreamviewer/install.sh
  tool_wanted stayup            && run "stayup"            ./stayup/install.sh
  if tool_wanted wtalk; then
    run "wtalk setup (as $SUDO_USER)" sudo -u "$SUDO_USER" env PATH="$PATH" ./wtalk/setup.sh
    run "wtalk" ./wtalk/install.sh $WTALK_FLAG
  fi
  # shellcheck disable=SC2086
  tool_wanted nextdns-sidecar   && run "nextdns-sidecar"   ./nextdns-sidecar/install.sh $SC_FLAGS
  if tool_wanted remote-agent-connector; then
    if [ "$SKIP_RAC" = 1 ]; then echo "  · remote-agent-connector skipped over SSH"; else run "remote-agent-connector" ./remote-agent-connector/install.sh; fi
  fi
fi
if [ "$FROM_I" -le 4 ]; then
  tool_wanted browser-blitz && run "browser-blitz (as $SUDO_USER)" sudo -u "$SUDO_USER" env PATH="$PATH" ./browser-blitz/browser-blitz/install.sh
  if tool_wanted paseo && [ -d /Applications/Paseo.app ]; then
    if sudo -u "$SUDO_USER" launchctl print "gui/$(id -u "$SUDO_USER")/sh.paseo.daemon" >/dev/null 2>&1; then
      echo "  · paseo daemon already loaded — skipping (re-run scripts/setup-paseo-daemon.sh by hand to rewire)"
    else
      run "paseo daemon (as $SUDO_USER)" sudo -u "$SUDO_USER" env PATH="$PATH" ./scripts/setup-paseo-daemon.sh
    fi
  fi
  [ -z "$ONLY" ] && [ -x /usr/local/bin/demonlock ] && run "recommended spares" ./demonlock/register-recommended-spares.sh
fi
ROOT
  sudo env CODESIGN_IDENTITY="$CODESIGN_IDENTITY" REPO="$REPO" ONLY="$ONLY" FROM_I="$FROM_I" \
       WTALK_FLAG="$wtalk_flag" SKIP_RAC="$skip_rac" SC_FLAGS="${sc_flags[*]+"${sc_flags[*]}"}" \
       bash "$rootsh"
  local rc=$?; rm -f "$rootsh"
  [ "$rc" = 0 ] || exit "$rc"
}

# ---------------------------------------------------------------- 5 verify (root-free)
phase_verify() {
  echo "▸ phase 5 — verify"
  local fails=0
  agent_ok()  { launchctl print "gui/$UID_ME/$1" 2>/dev/null | grep -q "state = running" && ok "$1 running" || { echo "  ✗ $1 not running"; fails=$((fails+1)); }; }
  daemon_ok() { pgrep -qf "$1" && ok "$2 running" || { echo "  ✗ $2 not running"; fails=$((fails+1)); }; }
  tool_wanted demonlock         && { daemon_ok "Demonlock.app/Contents/MacOS/demonlock enforcerd" demonlock-enforcerd; agent_ok com.minh.demonlock.agent; demonlock status >/dev/null 2>&1 && ok "demonlock status" || { echo "  ✗ demonlock status"; fails=$((fails+1)); }; }
  tool_wanted blockrem          && { daemon_ok "Blockrem.app/Contents/MacOS/blockrem enforcerd" blockrem-enforcerd; agent_ok com.minh.blockrem.agent; }
  tool_wanted multistreamviewer && { agent_ok com.minh.multistreamviewer.agent; multistreamviewer status >/dev/null 2>&1 && ok "multistreamviewer status" || warn "multistreamviewer status non-zero (new install: health file appears within 30s)"; }
  tool_wanted stayup            && { pgrep -x stayup >/dev/null && ok "stayup running" || { echo "  ✗ stayup"; fails=$((fails+1)); }; }
  tool_wanted wtalk             && agent_ok com.minh.wtalk.agent
  tool_wanted nextdns-sidecar   && { daemon_ok "nextdns-sidecar enforcerd" nextdns-sidecar; nextdns-sidecar networklockdown status >/dev/null 2>&1 && ok "nextdns-sidecar status" || { echo "  ✗ nextdns-sidecar status"; fails=$((fails+1)); }; }
  tool_wanted remote-agent-connector && [ "$SSH_SESSION" = 0 ] && { pgrep -x RemoteAgentConnector >/dev/null && ok "RemoteAgentConnector running" || warn "RemoteAgentConnector not running (needs Get Permissions + rac setup)"; }
  tool_wanted browser-blitz     && { launchctl print "gui/$UID_ME/com.minh.browser-blitz" 2>/dev/null | grep -q "state = running" && ok "browser-blitz shim" || warn "browser-blitz shim not running"; }
  [ "$fails" = 0 ] || die "$fails verify failure(s)"
  ok "all verified"
}

# ---------------------------------------------------------------- 6 checklist (human)
phase_checklist() {
  echo "▸ phase 6 — the human steps (opening the panes for you)"
  local open_pane; open_pane() { open "x-apple.systempreferences:com.apple.preference.security?$1" 2>/dev/null || true; sleep 1; }
  open_pane Privacy_LocationServices; open_pane Privacy_Accessibility; open_pane Privacy_ScreenCapture; open_pane Privacy_Microphone; open_pane Privacy_Automation; open_pane Privacy_ListenEvent
  local nb="$REPO/nextdns-sidecar/profiles/no-browser-doh.mobileconfig" hd="$REPO/nextdns-sidecar/profiles/NextDNS-hardened.mobileconfig"
  [ -f "$hd" ] && ! [ -f "/Library/Managed Preferences/com.apple.dnsSettings.managed.plist" ] && open "$hd"
  [ -f "$nb" ] && ! profiles show 2>/dev/null | grep -q com.minh.nextdnslockdown.nobrowserdoh && open "$nb"
  # Karabiner rule for wtalk — scriptable (Karabiner hot-reloads karabiner.json)
  local kj="$HOME/.config/karabiner/karabiner.json"
  if [ -f "$kj" ] && command -v jq >/dev/null && ! grep -q "wtalk toggle" "$kj"; then
    local tmp; tmp="$(mktemp)"
    jq '.profiles[0].complex_modifications.rules += [{"description":"F5 → wtalk toggle","manipulators":[{"type":"basic","from":{"key_code":"f5"},"to":[{"shell_command":"/usr/local/bin/wtalk toggle"}]}]}]' "$kj" > "$tmp" && mv "$tmp" "$kj" && ok "Karabiner: F5 → wtalk toggle written"
  fi
  cat <<TXT

  Do these by hand (macOS won't let a script click them):
   1. Privacy & Security ▸ Location Services → Demonlock: Always
   2. Accessibility → Demonlock, Blockrem, multistreamviewer, wtalk, RemoteAgentConnector
   3. Screen Recording → multistreamviewer, RemoteAgentConnector
   4. Microphone → wtalk        5. Automation → RemoteAgentConnector
   6. Input Monitoring + driver-extension approval → Karabiner-Elements
   7. General ▸ Device Management → Install the two NextDNS profiles that just opened
   8. Chrome: chrome://extensions → Developer mode → Load unpacked → $REPO/browser-blitz/extension
   9. rac: Dock icon → Get Permissions; then \`rac setup\` (needs MIDDLEMAN reachable)
  Then, and only then, harden (README §3):
      sudo demonlock setpolicy '…' && sudo demonlock arm
      nextdns-sidecar networklockdown arm
      demonlock nosudo          # drops your daily admin — keep a recovery path until the release valve has proven it grants admin back
TXT
}

want preflight && phase_preflight
want secrets   && phase_secrets
want identity  && phase_identity
if want root || want user; then phase_root_and_user; fi
want verify    && phase_verify
want checklist && phase_checklist
echo; ok "install-all done"
