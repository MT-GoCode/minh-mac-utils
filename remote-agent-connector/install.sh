#!/bin/bash
# Install Remote Agent Connector: build+sign as your user, deploy the app root-owned to
# /Applications, install the `remote-agent-connector` + `rac` CLI to /usr/local/bin, and
# launch (which registers it as a Login Item). Run:  sudo ./install.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo ./install.sh"; exit 1; }
: "${SUDO_USER:?must be run via sudo (need SUDO_USER for the build keychain)}"
[ "$SUDO_USER" != root ] || { echo "don't run from a root shell (SUDO_USER=root) — run as your normal user via sudo."; exit 1; }
USER_NAME="$SUDO_USER"
USER_HOME="$(eval echo "~$USER_NAME")"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "▸ building + signing as $USER_NAME"
sudo -u "$USER_NAME" bash "$HERE/build.sh"

echo "▸ stopping any running instance"
sudo -u "$USER_NAME" osascript -e 'quit app "RemoteAgentConnector"' >/dev/null 2>&1 || true
sleep 1
pkill -x RemoteAgentConnector 2>/dev/null || true
pkill -f "ssh -N -i .*remote-agent-connector/tunnel_key" 2>/dev/null || true

echo "▸ deploying app root-owned to /Applications"
rm -rf "$USER_HOME/Applications/RemoteAgentConnector.app" /Applications/RemoteAgentConnector.app
cp -R "$HERE/RemoteAgentConnector.app" /Applications/RemoteAgentConnector.app
chown -R root:wheel /Applications/RemoteAgentConnector.app
chmod -R go-w /Applications/RemoteAgentConnector.app
xattr -dr com.apple.quarantine /Applications/RemoteAgentConnector.app 2>/dev/null || true

echo "▸ installing CLI: /usr/local/bin/remote-agent-connector (+ rac)"
install -d -m755 /usr/local/bin
install -m755 "$HERE/remote-agent-connector" /usr/local/bin/remote-agent-connector
ln -sf /usr/local/bin/remote-agent-connector /usr/local/bin/rac

echo "▸ scaffolding a blank config (you fill it in, then run: rac setup)"
sudo -u "$USER_NAME" /usr/local/bin/remote-agent-connector init || true

echo "▸ launching as $USER_NAME (registers a Login Item, shows in Dock)"
sudo -u "$USER_NAME" open /Applications/RemoteAgentConnector.app

cat <<EOF
✓ installed.  Next:
  1. Dock icon → right-click → "Get Permissions" (Screen Recording, Accessibility, Automation).
  2. Edit ~/.remote-agent-connector/config — set MIDDLEMAN and MACHINE_NAME.
  3. rac setup       (converges everything; rolls back if anything fails)
     rac status      (check the tunnel any time)
EOF

echo "▸ verifying demonlock will spare it"
bash "$HERE/../verify-spare.sh" /Applications/RemoteAgentConnector.app com.minh.remote-agent-connector
