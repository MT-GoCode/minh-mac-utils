#!/bin/zsh
# Install msv2 root-owned to /Applications (same pattern as multistreamviewer/wtalk/etc.)
# and register it in demonlock's spare list so a lockout doesn't kill it.
#
# Root-owned matters twice: (1) demonlock only spares a self-team app (BULCQM9J2V) when its
# bundle is root-owned in /Applications, and (2) it can't be swapped without sudo. A msv2
# kill is harmless anyway (it never moves windows — worst case you relaunch it), so the
# spare is a convenience, not a safety requirement.
#
# Run:  sudo ./install.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./install.sh"; exit 1; }
: "${SUDO_USER:?must be run via sudo (need SUDO_USER for the build keychain)}"
USER_NAME="$SUDO_USER"
USER_HOME="$(eval echo "~$USER_NAME")"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "▸ building + signing as $USER_NAME"
# `sudo -u minh codesign` has no security session, so it cannot open the login keychain and
# dies with errSecInternalComponent — leaving build/msv2.app ad-hoc signed, which demonlock
# will not spare. When that happens, build + sign in a real logged-in session first
# (`rac exec ./scripts/build.sh`), then deploy that bundle with SKIP_BUILD=1.
if [ "${SKIP_BUILD:-0}" = 1 ]; then
    echo "  SKIP_BUILD=1 — deploying the existing build/msv2.app"
    codesign --verify --strict "$HERE/build/msv2.app" \
        || { echo "  build/msv2.app is not validly signed — rebuild it first"; exit 1; }
else
    sudo -u "$USER_NAME" zsh "$HERE/scripts/build.sh"
fi

echo "▸ stopping any running instance"
pkill -x msv2 2>/dev/null && sleep 1 || true

echo "▸ deploying root-owned to /Applications (removing any old installs)"
rm -rf "$USER_HOME/Applications/msv2.app" /Applications/msv2.app
cp -R "$HERE/build/msv2.app" /Applications/msv2.app
chown -R root:wheel /Applications/msv2.app
chmod -R go-w /Applications/msv2.app
xattr -dr com.apple.quarantine /Applications/msv2.app 2>/dev/null || true

echo "▸ exposing CLI as ~/.local/bin/msv2"
sudo -u "$USER_NAME" mkdir -p "$USER_HOME/.local/bin"
sudo -u "$USER_NAME" ln -sf /Applications/msv2.app/Contents/MacOS/msv2 \
    "$USER_HOME/.local/bin/msv2"

echo "▸ registering demonlock spare (com.minh.msv2 → BULCQM9J2V)"
SET="/Library/Application Support/Demonlock/settings.json"
if [ -f "$SET" ]; then
    # A `spareApps` key in settings.json REPLACES demonlock's compiled default list
    # wholesale (Settings.swift: decode(...) ?? d.spareApps) — it is not merged. So never
    # seed one here: writing a partial list would silently un-spare everything missing
    # from it. Only patch an override that already exists; otherwise the compiled
    # defaults (which include com.minh.msv2) already cover us.
    /usr/bin/python3 - "$SET" <<'PY'
import json, sys
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception:
    d = {}
sp = d.get("spareApps")
if isinstance(sp, dict):
    sp["com.minh.msv2"] = "BULCQM9J2V"
    d["spareApps"] = sp
    json.dump(d, open(path, "w"), indent=2)
    print("  added to the existing settings.json spareApps override")
else:
    print("  no spareApps override — demonlock's compiled defaults already include it")
PY
else
    echo "  (demonlock not installed — skipped)"
fi

echo "▸ verifying demonlock will spare it"
bash "$HERE/../verify-spare.sh" /Applications/msv2.app com.minh.msv2

echo "▸ launching as $USER_NAME"
sudo -u "$USER_NAME" open /Applications/msv2.app

echo "✓ installed. Root-owned /Applications bundle (demonlock spares it)."
echo "  First run: grant Accessibility (raises windows) and, for thumbnails, Screen"
echo "  Recording — System Settings → Privacy & Security. Then relaunch."
echo "  Keys: hold ⌘⌥ = all desktops · ⌘⇥ = in-desktop switcher."
echo "  CLI: msv2 show|hide|toggle|new|gather|switch N|next|send N"