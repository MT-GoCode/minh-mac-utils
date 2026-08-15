#!/bin/zsh
# Remove stayup completely. Restores normal sleep first — quitting the app alone would
# leave the Mac unable to sleep, since the setting lives in macOS power management.
# Run:  sudo ./uninstall.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./uninstall.sh"; exit 1; }
USER_NAME="${SUDO_USER:-$(stat -f%Su /dev/console)}"
USER_HOME="$(eval echo "~$USER_NAME")"

echo "▸ restoring normal sleep (disablesleep 0)"
/usr/bin/pmset -a disablesleep 0 || true

echo "▸ stopping app"
pkill -x stayup 2>/dev/null && sleep 1 || true

echo "▸ removing bundle, CLI, sudoers rule"
rm -rf /Applications/stayup.app "$USER_HOME/Applications/stayup.app"
rm -f /usr/local/bin/stayup /etc/sudoers.d/stayup

echo "▸ removing demonlock spare"
SET="/Library/Application Support/Demonlock/settings.json"
if [ -f "$SET" ]; then
    /usr/bin/python3 - "$SET" <<'PY'
import json, sys
path = sys.argv[1]
try: d = json.load(open(path))
except Exception: sys.exit(0)
sp = d.get("spareApps")
if isinstance(sp, dict) and sp.pop("com.minh.stayup", None) is not None:
    d["spareApps"] = sp
    json.dump(d, open(path, "w"), indent=2)
    print("  removed com.minh.stayup from spare list")
PY
fi

echo "✓ uninstalled (normal sleep restored)"
