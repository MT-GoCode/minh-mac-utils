#!/bin/bash
# One installer for all of minh-mac-utils.
#   sudo ./install.sh --all          # everything, in dependency order (demonlock first)
#   sudo ./install.sh <app>          # just one (e.g. msv2, stayup, nextdns-sidecar)
#   ./install.sh --list              # what --all installs
#
# Each app carries an install.manifest (vars + a provide_bundle shim); the shared steps live in
# scripts/install-lib.sh. Complex apps (demonlock, nextdns-sidecar) declare APP_TYPE=passthrough and run
# their own installer. demonlock goes first because it owns the spare list the others register into.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

# demonlock first (spare registry); then spared GUI apps; then daemons; then CLIs.
ALL_ORDER=(demonlock msv2 stayup remote-agent-connector wtalk nextdns-sidecar \
           agentic-browser-setup betterat fade-play-pause-chrome)

usage() { echo "usage: sudo $0 --all | <app>"; echo "apps (--all order): ${ALL_ORDER[*]}"; }

install_one() {
  local app="$1" dir="$ROOT/$1"
  [ -d "$dir" ] || { echo "✗ no such app: $app"; return 1; }
  echo "══════ $app ══════"
  if [ -f "$dir/install.manifest" ]; then
    ( APP_DIR="$dir"; source "$ROOT/scripts/install-lib.sh"; source "$dir/install.manifest"; dl_run_manifest )
  elif [ -f "$dir/install.sh" ]; then
    ( cd "$dir" && bash install.sh )   # fallback: app's own installer (bash, so the +x bit doesn't matter)
  else
    echo "✗ $app has no install.manifest or install.sh"; return 1
  fi
}

case "${1:-}" in
  --list|-l) usage; exit 0 ;;
  ""|-h|--help) usage; exit 0 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $0 $*"; exit 1; }
: "${SUDO_USER:?must run via sudo (need SUDO_USER)}"

if [ "$1" = --all ]; then
  fails=()
  for a in "${ALL_ORDER[@]}"; do install_one "$a" || fails+=("$a"); echo; done
  [ "${#fails[@]}" -eq 0 ] && echo "✓ all installed." || echo "⚠️  finished with failures: ${fails[*]}"
else
  install_one "$1"
fi
