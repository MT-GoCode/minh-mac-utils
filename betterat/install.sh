#!/bin/bash
# betterat — a bash CLI utility. Not spared, no daemon. Self-contained: declares its manifest, calls
# the shared install-lib to place it on PATH root-owned.
set -uo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$APP_DIR/../scripts/install-lib.sh"
dl_require_root

APP_TYPE=cli
APP_NAME=betterat
CLI=betterat
SPARED=no
provide_bundle() { echo "$APP_DIR/betterat"; }

dl_run_manifest
