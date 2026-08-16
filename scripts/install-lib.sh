#!/bin/bash
# Shared install primitives for minh-mac-utils. Sourced by the top-level ./install.sh and by each app's
# install.manifest. Every function assumes it runs as ROOT (the driver asserts that) with SUDO_USER set.
# Manifests declare a few vars + a provide_bundle() shim; dl_run_manifest wires the common steps.

dl_require_root() {   # each app's install.sh calls this after sourcing, before declaring its manifest
  [ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo ${BASH_SOURCE[1]:-$0}"; exit 1; }
  : "${SUDO_USER:?must run via sudo (need SUDO_USER)}"
}

dl_user()      { echo "${SUDO_USER:?must run via sudo}"; }
dl_user_home() { eval echo "~$(dl_user)"; }
dl_ok()   { echo "  ✓ $*"; }
dl_warn() { echo "  ⚠️  $*" >&2; }

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

# Install a plain script/binary as a root-owned CLI.
dl_install_script_cli() {  # <cli_name> <src>
  [ -e "$2" ] || { echo "✗ no file at: $2"; return 1; }
  install -m 0755 -o root -g wheel "$2" "/usr/local/bin/$1" && dl_ok "/usr/local/bin/$1"
}

# Install + (re)load a launchd job. kind = daemon | agent.
dl_install_launchd() {  # <plist_src> <daemon|agent>
  local src="$1" kind="$2" label dst uid
  [ -f "$src" ] || { echo "✗ no plist at: $src"; return 1; }
  label="$(basename "$src" .plist)"
  if [ "$kind" = daemon ]; then dst="/Library/LaunchDaemons/$(basename "$src")"
  else                          dst="/Library/LaunchAgents/$(basename "$src")"; fi
  cp "$src" "$dst"; chown root:wheel "$dst"; chmod 644 "$dst"
  if [ "$kind" = daemon ]; then
    launchctl bootout "system/$label" 2>/dev/null || true; sleep 1
    launchctl bootstrap system "$dst" 2>/dev/null || launchctl kickstart -k "system/$label" 2>/dev/null || true
  else
    uid="$(id -u "$(dl_user)")"
    launchctl bootout "gui/$uid/$label" 2>/dev/null || true; sleep 1
    launchctl bootstrap "gui/$uid" "$dst" 2>/dev/null || launchctl kickstart -k "gui/$uid/$label" 2>/dev/null || true
  fi
  dl_ok "launchd $kind $label"
}

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

# Register an app in demonlock's spare list — IMMEDIATE (we're root; the installer is the main caller of
# the sudo path). No-op with a note if demonlock isn't installed yet.
dl_register_spare() {  # <name> <bid> <tid> [--no-root-ownership]
  local dl=/Applications/Demonlock.app/Contents/MacOS/demonlock
  [ -x "$dl" ] || { echo "  · demonlock not installed — skipping spare registration for $1"; return 0; }
  "$dl" safe-apps register --name "$1" --bid "$2" --tid "$3" ${4:+"$4"} && dl_ok "registered spare '$1'"
}

# Build a swift app as the user (via its scripts/build.sh if present) and echo the located .app. Apps
# call this from provide_bundle. Falls back to an already-built bundle if the build step is absent/fails.
dl_swift_bundle() {  # <bundle_name>
  local name="$1" c
  if [ -x "$APP_DIR/scripts/build.sh" ]; then
    sudo -u "$(dl_user)" bash -c "cd '$APP_DIR' && ./scripts/build.sh" >&2 || dl_warn "build.sh failed — using any existing bundle"
  fi
  for c in "$APP_DIR/build/$name" "$APP_DIR/dist/$name" "$APP_DIR/$name"; do
    [ -d "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

# The install flow, driven by the sourced manifest. gui-app / cli get the common wiring; complex apps
# (demonlock, nextdns-sidecar, wtalk, remote-agent-connector, fade) keep their own bespoke install.sh
# and may source this lib for individual steps.
dl_run_manifest() {
  case "${APP_TYPE:-gui-app}" in
    gui-app)
      local art; art="$(provide_bundle)" || { echo "✗ ${APP_NAME}: provide_bundle failed"; return 1; }
      dl_deploy_app "$art" "$BUNDLE" || return 1
      [ -n "${CLI:-}" ] && dl_install_cli "$CLI" "/Applications/$BUNDLE/Contents/MacOS/${CLI_EXEC:-$CLI}"
      declare -F post_install >/dev/null && post_install
      [ "${SPARED:-no}" = yes ] && dl_register_spare "$APP_NAME" "$BUNDLE_ID" "$TEAM_ID" "${SPARE_FLAG:-}"
      ;;
    cli)
      local art; art="$(provide_bundle)" || { echo "✗ ${APP_NAME}: provide_bundle failed"; return 1; }
      dl_install_script_cli "$CLI" "$art"
      declare -F post_install >/dev/null && post_install
      ;;
    *) echo "✗ ${APP_NAME:-app}: unknown APP_TYPE '${APP_TYPE:-}'"; return 1 ;;
  esac
}
