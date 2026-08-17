#!/bin/zsh
# Remove multistreamviewer completely and de-register its demonlock spare.
# Run:  sudo ./uninstall.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./uninstall.sh"; exit 1; }
USER_NAME="${SUDO_USER:-$(stat -f%Su /dev/console)}"
USER_HOME="$(eval echo "~$USER_NAME")"

echo "▸ stopping app"
pkill -x multistreamviewer 2>/dev/null && sleep 1 || true

echo "▸ removing bundle + CLI symlink"
rm -rf /Applications/multistreamviewer.app "$USER_HOME/Applications/multistreamviewer.app"
rm -f /usr/local/bin/multistreamviewer

echo "▸ clearing permissions + preferences"
tccutil reset Accessibility com.minh.multistreamviewer 2>/dev/null || true
tccutil reset ScreenCapture com.minh.multistreamviewer 2>/dev/null || true
rm -rf "$USER_HOME/Library/Application Support/multistreamviewer"

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
lst = d.get("safeAppsUser")
if isinstance(lst, list):
    new = [a for a in lst if a.get("bid") != "com.minh.multistreamviewer"]
    if len(new) != len(lst):
        d["safeAppsUser"] = new
        json.dump(d, open(path, "w"), indent=2, sort_keys=True)
        print("  removed com.minh.multistreamviewer from spare list")
PY
fi

echo "✓ uninstalled"