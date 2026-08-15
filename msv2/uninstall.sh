#!/bin/zsh
# Remove msv2 completely and de-register its demonlock spare.
# Run:  sudo ./uninstall.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./uninstall.sh"; exit 1; }
USER_NAME="${SUDO_USER:-$(stat -f%Su /dev/console)}"
USER_HOME="$(eval echo "~$USER_NAME")"

echo "▸ stopping app"
pkill -x msv2 2>/dev/null && sleep 1 || true

echo "▸ removing bundle + CLI symlink"
rm -rf /Applications/msv2.app "$USER_HOME/Applications/msv2.app"
rm -f "$USER_HOME/.local/bin/msv2"

echo "▸ clearing permissions + preferences"
tccutil reset Accessibility com.minh.msv2 2>/dev/null || true
tccutil reset ScreenCapture com.minh.msv2 2>/dev/null || true
rm -rf "$USER_HOME/Library/Application Support/msv2"

echo "▸ removing demonlock spare"
SET="/Library/Application Support/Demonlock/settings.json"
if [ -f "$SET" ]; then
    /usr/bin/python3 - "$SET" <<'PY'
import json, sys
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(0)
sp = d.get("spareApps")
if isinstance(sp, dict) and sp.pop("com.minh.msv2", None) is not None:
    d["spareApps"] = sp
    json.dump(d, open(path, "w"), indent=2)
    print("  removed com.minh.msv2 from spare list")
PY
fi

echo "✓ uninstalled"