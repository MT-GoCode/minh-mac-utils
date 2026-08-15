#!/bin/zsh
# Install stayup root-owned to /Applications (house pattern: demonlock only spares a
# self-team app whose bundle is root-owned), install the CLI, and write the narrow
# passwordless rule that lets the menu-bar toggle work without a prompt.
#
# Run:  sudo ./install.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./install.sh"; exit 1; }
: "${SUDO_USER:?must be run via sudo (need SUDO_USER for the build keychain)}"
USER_NAME="$SUDO_USER"
USER_HOME="$(eval echo "~$USER_NAME")"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "▸ building + signing as $USER_NAME"
sudo -u "$USER_NAME" zsh "$HERE/scripts/build.sh"

echo "▸ stopping any running instance"
pkill -x stayup 2>/dev/null && sleep 1 || true

echo "▸ deploying root-owned to /Applications"
rm -rf "$USER_HOME/Applications/stayup.app" /Applications/stayup.app
cp -R "$HERE/build/stayup.app" /Applications/stayup.app
chown -R root:wheel /Applications/stayup.app
chmod -R go-w /Applications/stayup.app
xattr -dr com.apple.quarantine /Applications/stayup.app 2>/dev/null || true

echo "▸ installing CLI /usr/local/bin/stayup"
mkdir -p /usr/local/bin
cat > /usr/local/bin/stayup <<'EOF'
#!/bin/bash
exec /Applications/stayup.app/Contents/MacOS/stayup "$@"
EOF
chmod 755 /usr/local/bin/stayup
chown root:wheel /usr/local/bin/stayup

# Exactly two commands, fully qualified with their arguments — this grants the ability to
# toggle lid-closed-sleep and nothing else. (`pmset -a disablesleep` is the only knob that
# keeps a closed-lid Mac awake; caffeinate/Amphetamine assertions can't do it.)
echo "▸ writing passwordless rule /etc/sudoers.d/stayup"
cat > /etc/sudoers.d/stayup <<EOF
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
EOF
chmod 440 /etc/sudoers.d/stayup
chown root:wheel /etc/sudoers.d/stayup
visudo -cf /etc/sudoers.d/stayup >/dev/null || { echo "  ⚠️  invalid sudoers entry — removing"; rm -f /etc/sudoers.d/stayup; }

echo "▸ registering demonlock spare (com.minh.stayup → BULCQM9J2V)"
SET="/Library/Application Support/Demonlock/settings.json"
if [ -f "$SET" ]; then
    /usr/bin/python3 - "$SET" <<'PY'
import json, sys
path = sys.argv[1]
try: d = json.load(open(path))
except Exception: d = {}
sp = d.get("spareApps")
if isinstance(sp, dict):                      # only merge into an existing override;
    sp["com.minh.stayup"] = "BULCQM9J2V"      # otherwise the compiled defaults already
    d["spareApps"] = sp                       # carry it (see demonlock Settings.swift)
    json.dump(d, open(path, "w"), indent=2)
    print("  added to settings.json spareApps")
else:
    print("  settings.json has no spareApps override — compiled defaults apply")
PY
else
    echo "  (demonlock not installed — skipped)"
fi

echo "▸ verifying demonlock will spare it"
bash "$HERE/../verify-spare.sh" /Applications/stayup.app com.minh.stayup

echo "▸ launching as $USER_NAME"
sudo -u "$USER_NAME" open /Applications/stayup.app

echo "✓ installed. Menu bar: bolt = awake-with-lid-closed is ON, bolt.slash = normal sleep."
echo "  CLI: stayup on|off|status"
echo "  The setting persists across reboots until turned off — the menu bar icon is the reminder."
