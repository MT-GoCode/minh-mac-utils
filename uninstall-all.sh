#!/bin/bash
# uninstall-all.sh — remove every minh-mac-utils tool (reverse install order). Run as your normal user;
# calls sudo itself.  ./uninstall-all.sh [--purge]   (--purge also wipes each tool's state/credentials)
# Disarms the lockers first so nothing enforces against a half-removed system. Permissions (TCC) are
# NOT reset — re-install without re-clicking everything.
set -uo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"; cd "$REPO"
[ "$(id -un)" != root ] || { echo "run as your normal user"; exit 1; }
P="${1:-}"
sudo -v || exit 1
sudo bash -c "
set -uo pipefail; cd '$REPO'
sudo nextdns-sidecar networklockdown disarm 2>/dev/null || true
[ -x /usr/local/bin/demonlock ] && demonlock disarm 2>/dev/null || true
sudo -u '$USER' rac teardown 2>/dev/null || true
for t in nextdns-sidecar wtalk multistreamviewer stayup blockrem remote-agent-connector; do
  [ -x ./\$t/uninstall.sh ] && { echo; echo '━━ '\$t; ./\$t/uninstall.sh $P || true; }
done
sudo -u '$USER' ./scripts/unset-paseo-daemon.sh 2>/dev/null || true
sudo -u '$USER' ./browser-blitz/browser-blitz/install.sh --uninstall 2>/dev/null || true
echo; echo '━━ demonlock (last — everything else de-registered its spare first)'
./demonlock/uninstall.sh $P || true
"
echo; echo "  ✓ uninstall-all done"
