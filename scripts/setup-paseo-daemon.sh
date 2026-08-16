#!/usr/bin/env bash
# setup-paseo-daemon.sh — idempotent: run the Paseo daemon under launchd and
# make the desktop app a pure client that attaches instead of spawning.
#
#   1. flips manageBuiltInDaemon=false in the app's desktop-settings.json
#   2. installs LaunchAgent sh.paseo.daemon  (RunAtLoad + KeepAlive, foreground)
#   3. installs LaunchAgent sh.paseo.refresh (4:30am; restarts the daemon only
#      when the app auto-updated underneath it AND no agent is running)
#
# Safe to re-run. Re-running rewrites both plists and bounces the daemon.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASEO_BIN="$(command -v paseo || true)"
[ -n "$PASEO_BIN" ] || PASEO_BIN="$HOME/.local/bin/paseo"
[ -x "$PASEO_BIN" ] || { echo "paseo CLI not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }
SETTINGS="$HOME/Library/Application Support/Paseo/desktop-settings.json"
LA="$HOME/Library/LaunchAgents"
U="$(id -u)"
mkdir -p "$LA" "$HOME/.paseo"

echo "==> desktop app: connect-only (manageBuiltInDaemon=false)"
if [ -f "$SETTINGS" ]; then
  tmp="$(mktemp)"
  jq '.settings.daemon.manageBuiltInDaemon = false' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
fi

echo "==> handing daemon ownership to launchd"
APP_WAS_RUNNING=0
if pgrep -qf "Paseo.app/Contents/MacOS/Paseo$"; then
  APP_WAS_RUNNING=1
  osascript -e 'quit app "Paseo"' 2>/dev/null || true
  sleep 2
fi
"$PASEO_BIN" daemon stop >/dev/null 2>&1 || true
sleep 1

cat > "$LA/sh.paseo.daemon.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>sh.paseo.daemon</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PASEO_BIN</string>
    <string>daemon</string>
    <string>start</string>
    <string>--foreground</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$HOME/.paseo/launchd-daemon.log</string>
  <key>StandardErrorPath</key><string>$HOME/.paseo/launchd-daemon.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
EOF

cat > "$LA/sh.paseo.refresh.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>sh.paseo.refresh</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPTS_DIR/paseo-refresh.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>4</integer>
    <key>Minute</key><integer>30</integer>
  </dict>
  <key>StandardOutPath</key><string>$HOME/.paseo/refresh.log</string>
  <key>StandardErrorPath</key><string>$HOME/.paseo/refresh.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
EOF

for label in sh.paseo.daemon sh.paseo.refresh; do
  launchctl bootout "gui/$U/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$U" "$LA/$label.plist"
done

echo "==> waiting for daemon"
for _ in $(seq 1 15); do
  sleep 1
  if "$PASEO_BIN" --json daemon status >/dev/null 2>&1; then break; fi
done
"$PASEO_BIN" --json daemon status | jq -r '"daemon v\(.daemonVersion) pid \(.pid) desktopManaged=\(.desktopManaged) listen \(.listen)"'

if [ "$APP_WAS_RUNNING" = 1 ]; then
  echo "==> reopening Paseo app (as client)"
  open -a "$HOME/Applications/Paseo.app" 2>/dev/null || open -a Paseo || true
fi

# Register the paseo DAEMON as a demonlock spare so a lockout can't kill it (the paseo desktop GUI stays
# blocklisted — demonlock still kills that). demonlock ships no base list, so we register here. Needs
# root (this script runs as you), so sudo may prompt — that's fine.
echo "==> registering paseo daemon as a demonlock spare (needs root — may prompt)"
DL=/Applications/Demonlock.app/Contents/MacOS/demonlock
if [ -x "$DL" ]; then
  sudo "$DL" safe-apps register --name paseo-daemon --bid sh.paseo.desktop.helper --tid 99ZMJMKU9Y --no-root-ownership \
    || echo "    ⚠️  register failed — run manually: sudo demonlock safe-apps register --name paseo-daemon --bid sh.paseo.desktop.helper --tid 99ZMJMKU9Y --no-root-ownership"
else
  echo "    (demonlock not installed yet — after installing it, run:"
  echo "     sudo demonlock safe-apps register --name paseo-daemon --bid sh.paseo.desktop.helper --tid 99ZMJMKU9Y --no-root-ownership)"
fi

echo "==> done: daemon owned by launchd (sh.paseo.daemon), nightly refresh at 4:30"
