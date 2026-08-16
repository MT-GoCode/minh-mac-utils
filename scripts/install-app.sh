#!/bin/bash
# Shared per-app installer runner: `install-app.sh <app_dir>`. Each app's own install.sh just execs this
# with its own dir, so ALL install logic lives here + install-lib.sh (placed once, elsewhere) and each
# app owns only its install.manifest (vars + provide_bundle).
set -uo pipefail
APP_DIR="${1:?usage: install-app.sh <app_dir>}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$APP_DIR/install.manifest" ] || { echo "✗ no install.manifest in $APP_DIR"; exit 1; }
source "$REPO/scripts/install-lib.sh"
source "$APP_DIR/install.manifest"
if [ "${RUN_AS:-root}" != user ]; then
  [ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $APP_DIR/install.sh"; exit 1; }
  : "${SUDO_USER:?must run via sudo}"
fi
dl_run_manifest
