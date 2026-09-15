#!/bin/bash
# Shared install primitives for minh-mac-utils. Sourced by each app's install.sh / uninstall.sh and by
# the top-level install-all.sh. Every dl_* function assumes ROOT with SUDO_USER set unless noted.
# Manifests declare a few vars + provide_bundle()/post_install(); dl_run_manifest wires the flow:
#   build (provide_bundle) → [dl_stop if STOP_FIRST=yes] → deploy → CLI → post_install → spare.
# Order matters: BUILD BEFORE STOP (a failed build must leave the running copy alone), and daemons that
# enforce (demonlock, blockrem) are NOT stopped before deploy — their launchd reload happens in
# post_install via dl_install_launchd (bootout → bootstrap), so there is no enforcement gap.

dl_require_root() {   # each app's install.sh calls this after sourcing, before declaring its manifest
  [ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo ${BASH_SOURCE[1]:-$0}"; exit 1; }
  : "${SUDO_USER:?must run via sudo (need SUDO_USER)}"
  # Refuse a ROOT shell: SUDO_USER=root would deploy for the wrong user and (for demonlock) enforce
  # the wrong console user. Run as your normal user via sudo, not from `sudo -s` / a root prompt.
  [ "$SUDO_USER" != root ] || { echo "✗ don't run from a root shell (SUDO_USER=root). Exit it, then run 'sudo ./<app>/install.sh' as your normal user."; exit 1; }
}

dl_user()      { echo "${SUDO_USER:?must run via sudo}"; }
dl_user_uid()  { id -u "$(dl_user)"; }
dl_user_home() { local h; h="$(/usr/bin/dscl . -read "/Users/$(dl_user)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"; echo "${h:-/Users/$(dl_user)}"; }
# Uninstallers only: the console user when SUDO_USER is empty/root (uninstall from a root/Recovery
# shell is the lock-out escape hatch, so it must keep working).
dl_console_user() { local u="${SUDO_USER:-}"; [ -n "$u" ] && [ "$u" != root ] && { echo "$u"; return; }; stat -f%Su /dev/console; }
dl_ok()   { echo "  ✓ $*"; }
dl_warn() { echo "  ⚠️  $*" >&2; }
dl_die()  { echo "✗ $*" >&2; exit 1; }

# ---------------------------------------------------------------- bundle selection + build

# Pick the bundle to deploy. Explicit rungs (a toolchain always wins — the old automatic "no Dev ID →
# committed dist" rung silently installed a month-stale bundle on any no-Dev-ID machine):
#   PREBUILT=1 (from --prebuilt)        → the committed dist, no build, no keychain prompt  [explicit only]
#   Xcode CLT present                    → build as the user (the ladder picks Dev ID → self-signed → ad-hoc)
#   no CLT, committed dist present       → deploy it
#   else                                 → fail with the CLT hint
# Never falls back to "any existing bundle" on a build FAILURE — that deploys stale code silently.
# Echoes the chosen .app path. CODESIGN_IDENTITY (if set by install-all) is forwarded into the build
# (sudo's env_reset would strip it, and the ladder would re-prompt the keychain per app).
dl_pick_bundle() {  # <built_app_path> <build_script> [committed_dist_app]
  local built="$1" build="$2" dist="${3:-}"
  if [ "${PREBUILT:-0}" = 1 ]; then
    [ -n "$dist" ] && [ -d "$dist" ] || { echo "✗ --prebuilt but no committed dist at: $dist" >&2; return 1; }
    echo "▸ --prebuilt: deploying $dist as-is (no build, no keychain)" >&2
    echo "$dist"; return 0
  fi
  if xcode-select -p >/dev/null 2>&1; then
    echo "▸ building + signing as $(dl_user)" >&2
    sudo -u "$(dl_user)" env ${CODESIGN_IDENTITY:+CODESIGN_IDENTITY="$CODESIGN_IDENTITY"} bash "$build" >&2 \
      || { echo "✗ build failed — not deploying anything (fix the build, or use --prebuilt if a committed dist exists)" >&2; return 1; }
    [ -d "$built" ] || { echo "✗ build produced no bundle at: $built" >&2; return 1; }
    echo "$built"; return 0
  fi
  if [ -n "$dist" ] && [ -d "$dist" ]; then
    echo "▸ no Swift toolchain — deploying the committed prebuilt $dist" >&2
    echo "$dist"; return 0
  fi
  echo "✗ no Swift toolchain (xcode-select --install) and no committed prebuilt bundle." >&2
  return 1
}

# Build a swift app as the user via its scripts/build.sh and echo the located .app. NO fallback to a
# stale bundle on failure.
dl_swift_bundle() {  # <bundle_name>
  local name="$1"
  [ -x "$APP_DIR/scripts/build.sh" ] || { echo "✗ no $APP_DIR/scripts/build.sh" >&2; return 1; }
  sudo -u "$(dl_user)" env ${CODESIGN_IDENTITY:+CODESIGN_IDENTITY="$CODESIGN_IDENTITY"} bash -c "cd '$APP_DIR' && ./scripts/build.sh" >&2 \
    || { echo "✗ build.sh failed — not deploying" >&2; return 1; }
  local c
  for c in "$APP_DIR/build/$name" "$APP_DIR/$name"; do [ -d "$c" ] && { echo "$c"; return 0; }; done
  echo "✗ build.sh produced no $name" >&2; return 1
}

# ---------------------------------------------------------------- deploy / CLI

# Deploy a .app root-owned to /Applications, removing any old copy AND any ~/Applications duplicate (a
# user-owned dup would only be spared under the stricter rule — never leave one). chown/chmod so demonlock
# Regime A holds (root-owned, not group/other-writable, incl. the inner executable).
dl_deploy_app() {  # <src_app_path> <bundle_name>
  local src="$1" name="$2" home; home="$(dl_user_home)"
  [ -d "$src" ] || { echo "✗ no built bundle at: $src (build the app first)"; return 1; }
  rm -rf "$home/Applications/$name" "/Applications/$name"
  cp -R "$src" "/Applications/$name" || return 1
  chown -R root:wheel "/Applications/$name"
  chmod -R go-w "/Applications/$name"
  xattr -dr com.apple.quarantine "/Applications/$name" 2>/dev/null || true
  dl_ok "deployed /Applications/$name (root-owned)"
}

# Symlink a CLI in /usr/local/bin → a bundle executable.
dl_install_cli() {  # <cli_name> <target_exec_path>
  ln -sf "$2" "/usr/local/bin/$1" && dl_ok "/usr/local/bin/$1 → $2"
}

# Root-owned wrapper SCRIPT in /usr/local/bin (demonlock/blockrem/wtalk shape). Kept as a wrapper for
# parity with what's on every machine today — not because anything needs it: sudoers grants reference
# the bundle binary, never this path (review H4).
dl_install_cli_wrapper() {  # <cli_name> <target_exec_path>
  mkdir -p /usr/local/bin
  printf '#!/bin/bash\nexec "%s" "$@"\n' "$2" > "/usr/local/bin/$1"
  chmod 755 "/usr/local/bin/$1"; chown root:wheel "/usr/local/bin/$1"
  dl_ok "/usr/local/bin/$1 (wrapper → $2)"
}

# Install a plain script/binary as a root-owned CLI.
dl_install_script_cli() {  # <cli_name> <src>
  [ -e "$2" ] || { echo "✗ no file at: $2"; return 1; }
  install -m 0755 -o root -g wheel "$2" "/usr/local/bin/$1" && dl_ok "/usr/local/bin/$1"
}

# ---------------------------------------------------------------- stop / launchd

# Stop a running copy BEFORE deploy — only for apps whose launchd job would respawn mid-copy
# (KeepAlive SuccessfulExit=false) or that would otherwise end up with two GUI instances. `--pre fn`
# runs a graceful step first (rac's osascript quit + tunnel pkill).
dl_stop() {  # <procname> [--label L] [--domain gui|system] [--pre fn]
  local proc="$1" label="" domain=gui pre=""; shift
  while [ $# -gt 0 ]; do case "$1" in
    --label) label="$2"; shift 2;; --domain) domain="$2"; shift 2;; --pre) pre="$2"; shift 2;;
    *) echo "dl_stop: unknown arg $1" >&2; return 1;; esac; done
  [ -n "$pre" ] && "$pre"
  if [ -n "$label" ]; then
    if [ "$domain" = system ]; then launchctl bootout "system/$label" 2>/dev/null || true
    else launchctl bootout "gui/$(dl_user_uid)/$label" 2>/dev/null || true; fi
  fi
  pkill -x "$proc" 2>/dev/null && sleep 1 || true
}

# "Loaded" is not "running": parse `launchctl print` for state = running + a pid, so a crash-looping
# KeepAlive job fails verification instead of printing ✓.
dl_verify_launchd() {  # <label> <gui|system>
  local label="$1" domain="$2" tgt out i
  if [ "$domain" = system ]; then tgt="system/$label"; else tgt="gui/$(dl_user_uid)/$label"; fi
  for i in 1 2 3 4 5 6; do
    out="$(launchctl print "$tgt" 2>/dev/null)" || out=""
    if printf '%s' "$out" | grep -q "state = running" && printf '%s' "$out" | grep -qE "pid = [0-9]+"; then
      dl_ok "launchd $tgt running"; return 0
    fi
    sleep 1
  done
  echo "✗ $tgt is not running." >&2
  if [ "$domain" = gui ]; then
    echo "  (no console session? log in locally, then: launchctl bootstrap gui/$(dl_user_uid) /Library/LaunchAgents/$label.plist)" >&2
  else
    echo "  (see: launchctl print $tgt · the daemon's log under /Library/Application Support/<App>/logs)" >&2
  fi
  return 1
}

# Install + (re)load a launchd job, then VERIFY it is running (non-zero if not — never swallowed).
#   kind = daemon | agent
#   --as-user       bootstrap the gui job as the user (wtalk's shape) instead of as root
#   --sed 'K=V'     substitute K→V in the plist (repeatable; '#' is the sed delimiter, so no '#' in V)
#   --no-verify     skip the running check (only for jobs that legitimately exit, none today)
dl_install_launchd() {  # <plist_src> <daemon|agent> [--as-user] [--sed K=V]... [--no-verify]
  local src="$1" kind="$2"; shift 2
  local asuser=0 verify=1 seds=() label dst uid
  while [ $# -gt 0 ]; do case "$1" in
    --as-user) asuser=1; shift;; --no-verify) verify=0; shift;;
    --sed) seds+=("$2"); shift 2;; *) echo "dl_install_launchd: unknown arg $1" >&2; return 1;; esac; done
  [ -f "$src" ] || { echo "✗ no plist at: $src"; return 1; }
  label="$(basename "$src" .plist)"
  if [ "$kind" = daemon ]; then dst="/Library/LaunchDaemons/$(basename "$src")"
  else                          dst="/Library/LaunchAgents/$(basename "$src")"; fi
  cp "$src" "$dst"; chown root:wheel "$dst"; chmod 644 "$dst"
  local kv
  for kv in "${seds[@]+"${seds[@]}"}"; do
    /usr/bin/sed -i '' "s#${kv%%=*}#${kv#*=}#g" "$dst"
  done
  if [ "$kind" = daemon ]; then
    launchctl bootout "system/$label" 2>/dev/null || true; sleep 2
    launchctl bootstrap system "$dst" 2>/dev/null || launchctl kickstart -k "system/$label" 2>/dev/null || true
    [ "$verify" = 1 ] && { dl_verify_launchd "$label" system || return 1; }
  else
    uid="$(dl_user_uid)"
    if [ "$asuser" = 1 ]; then
      sudo -u "$(dl_user)" launchctl bootout "gui/$uid/$label" 2>/dev/null || true; sleep 2
      sudo -u "$(dl_user)" launchctl bootstrap "gui/$uid" "$dst" 2>/dev/null \
        || sudo -u "$(dl_user)" launchctl kickstart -k "gui/$uid/$label" 2>/dev/null || true
    else
      launchctl bootout "gui/$uid/$label" 2>/dev/null || true; sleep 2
      launchctl bootstrap "gui/$uid" "$dst" 2>/dev/null || launchctl kickstart -k "gui/$uid/$label" 2>/dev/null || true
    fi
    [ "$verify" = 1 ] && { dl_verify_launchd "$label" gui || return 1; }
  fi
  dl_ok "launchd $kind $label"
}

# User-level (no root) LaunchAgent: write the plist from stdin into ~/Library/LaunchAgents, (re)load,
# verify running. For browser-blitz / paseo, which run as you.
dl_user_launchd() {  # <label>   (plist body on stdin)
  local label="$1" dir="$HOME/Library/LaunchAgents" dst uid out i
  dst="$dir/$label.plist"; uid="$(id -u)"
  mkdir -p "$dir"; cat > "$dst"
  launchctl bootout "gui/$uid/$label" 2>/dev/null || true; sleep 1
  launchctl bootstrap "gui/$uid" "$dst" 2>/dev/null || launchctl kickstart -k "gui/$uid/$label" 2>/dev/null || true
  for i in 1 2 3 4 5 6; do
    out="$(launchctl print "gui/$uid/$label" 2>/dev/null)" || out=""
    printf '%s' "$out" | grep -q "state = running" && { echo "  ✓ $label running"; return 0; }
    sleep 1
  done
  echo "✗ gui/$uid/$label is not running (launchctl print gui/$uid/$label)" >&2; return 1
}

# ---------------------------------------------------------------- sudoers / spares

# Refuse to write a passwordless grant if /usr/local[/bin] is user-writable (would be arbitrary root). H4.
dl_assert_usrlocal() {
  local d owner mode
  for d in /usr/local /usr/local/bin; do
    [ -d "$d" ] || continue
    owner="$(/usr/bin/stat -f%u "$d")"; mode="$(/usr/bin/stat -f%Lp "$d")"
    if [ "$owner" != 0 ] || [ "$(( 8#$mode & 8#022 ))" != 0 ]; then
      echo "✗ $d is not root-owned / is group/other-writable — refusing to add a sudoers grant."
      echo "  Fix: sudo chown root:wheel $d && sudo chmod go-w $d"; return 1
    fi
  done
}

# Write a validated passwordless sudoers file from the given lines.
dl_write_sudoers() {  # <name> <line...>
  local name="$1"; shift
  dl_assert_usrlocal || return 1
  local f="/etc/sudoers.d/$name"; : > "$f"
  printf '%s\n' "$@" >> "$f"
  chown root:wheel "$f"; chmod 440 "$f"
  visudo -cf "$f" >/dev/null 2>&1 || { dl_warn "invalid sudoers $name — removing"; rm -f "$f"; return 1; }
  dl_ok "sudoers /etc/sudoers.d/$name"
}

# Register an app in demonlock's spare list — IMMEDIATE (we're root). No-op with a note if demonlock
# isn't installed yet (install-all orders demonlock first so this never fires there).
dl_register_spare() {  # <name(unused)> <bid> <tid> [--no-root-ownership]
  local dl=/Applications/Demonlock.app/Contents/MacOS/demonlock
  [ -x "$dl" ] || { echo "  · demonlock not installed — skipping spare registration for $2 (install demonlock, then: sudo demonlock safe-apps register $2)"; return 0; }
  if [ "${4:-}" = "--no-root-ownership" ]; then
    "$dl" safe-apps register "$2" --no-root-ownership --tid "$3" && dl_ok "registered spare '$2'"
  else
    "$dl" safe-apps register "$2" && dl_ok "registered spare '$2'"   # root-owned: bundle only
  fi
}

# Drop an app from demonlock's spare list (root; used by uninstallers). Silent no-op without demonlock.
dl_unregister_spare() {  # <bid>
  local dl=/Applications/Demonlock.app/Contents/MacOS/demonlock
  [ -x "$dl" ] || return 0
  "$dl" safe-apps remove "$1" >/dev/null 2>&1 && echo "  removed $1 from the demonlock spare list" || true
}

# ---------------------------------------------------------------- uninstall

# The common uninstall: stop launchd jobs, kill the process, remove app + CLIs + plists + spare entry.
# Keeps the support dir unless --purge (state/credentials survive a reinstall). NO tccutil reset unless
# --tcc <bid> is given (resetting means re-clicking every permission after `uninstall-all; install-all`).
# Runs from a root shell too (dl_console_user) — that is the lock-out escape.
dl_uninstall_common() {  # --app Bundle.app [--proc name] [--cli name]... [--daemon label]... [--agent label]... [--support dir] [--purge] [--tcc bid] [--bid bid]
  local app="" proc="" support="" purge=0 tcc="" bid="" clis=() daemons=() agents=() u uid
  while [ $# -gt 0 ]; do case "$1" in
    --app) app="$2"; shift 2;; --proc) proc="$2"; shift 2;; --cli) clis+=("$2"); shift 2;;
    --daemon) daemons+=("$2"); shift 2;; --agent) agents+=("$2"); shift 2;; --support) support="$2"; shift 2;;
    --purge) purge=1; shift;; --tcc) tcc="$2"; shift 2;; --bid) bid="$2"; shift 2;;
    *) echo "dl_uninstall_common: unknown arg $1" >&2; return 1;; esac; done
  [ "$(id -u)" -eq 0 ] || { echo "run with sudo"; return 1; }
  u="$(dl_console_user)"; uid="$(id -u "$u" 2>/dev/null || echo 501)"
  local l
  for l in "${daemons[@]+"${daemons[@]}"}"; do launchctl bootout "system/$l" 2>/dev/null || true; rm -f "/Library/LaunchDaemons/$l.plist"; done
  for l in "${agents[@]+"${agents[@]}"}";  do launchctl bootout "gui/$uid/$l" 2>/dev/null || true; rm -f "/Library/LaunchAgents/$l.plist"; done
  [ -n "$proc" ] && { pkill -x "$proc" 2>/dev/null && sleep 1 || true; }
  [ -n "$app" ] && rm -rf "/Applications/$app" "/Users/$u/Applications/$app"
  for l in "${clis[@]+"${clis[@]}"}"; do rm -f "/usr/local/bin/$l"; done
  [ -n "$bid" ] && dl_unregister_spare "$bid"
  [ -n "$tcc" ] && { tccutil reset All "$tcc" >/dev/null 2>&1 || true; }
  if [ -n "$support" ]; then
    if [ "$purge" = 1 ]; then rm -rf "$support"; echo "  ✓ purged $support"
    else echo "  · kept $support — re-run with --purge to wipe it"; fi
  fi
  echo "  ✓ removed ${app:-} ${clis[*]+${clis[*]}} ${daemons[*]+${daemons[*]}} ${agents[*]+${agents[*]}}"
}

# ---------------------------------------------------------------- manifest runner

# gui-app flow: provide_bundle → [dl_stop if STOP_FIRST=yes] → deploy → CLI → post_install → spare.
# post_install returning non-zero aborts (no more silent partial installs).
dl_run_manifest() {
  case "${APP_TYPE:-gui-app}" in
    gui-app)
      local art; art="$(provide_bundle)" || { echo "✗ ${APP_NAME}: provide_bundle failed"; return 1; }
      if [ "${STOP_FIRST:-no}" = yes ]; then
        dl_stop "${PROC_NAME:-${CLI:-$APP_NAME}}" ${AGENT_LABEL:+--label "$AGENT_LABEL"} ${STOP_PRE:+--pre "$STOP_PRE"}
      fi
      dl_deploy_app "$art" "$BUNDLE" || return 1
      if [ -n "${CLI:-}" ]; then
        if [ "${CLI_WRAPPER:-no}" = yes ]; then dl_install_cli_wrapper "$CLI" "/Applications/$BUNDLE/Contents/MacOS/${CLI_EXEC:-$CLI}"
        else dl_install_cli "$CLI" "/Applications/$BUNDLE/Contents/MacOS/${CLI_EXEC:-$CLI}"; fi
      fi
      if declare -F post_install >/dev/null; then post_install || { echo "✗ ${APP_NAME}: post_install failed"; return 1; }; fi
      [ "${SPARED:-no}" = yes ] && dl_register_spare "$APP_NAME" "$BUNDLE_ID" "$TEAM_ID" "${SPARE_FLAG:-}"
      ;;
    cli)
      local art; art="$(provide_bundle)" || { echo "✗ ${APP_NAME}: provide_bundle failed"; return 1; }
      dl_install_script_cli "$CLI" "$art"
      if declare -F post_install >/dev/null; then post_install || return 1; fi
      ;;
    *) echo "✗ ${APP_NAME:-app}: unknown APP_TYPE '${APP_TYPE:-}'"; return 1 ;;
  esac
}
