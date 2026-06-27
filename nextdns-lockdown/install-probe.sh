#!/bin/bash
#
# install-probe.sh — install the captive-portal diagnostic logger as a user
# LaunchAgent. NO sudo: it runs in YOUR GUI session (so curl/dig see the same
# network context you do) and writes logs you can read without root.
#
# The agent fires nextdns-lockdown-probe on every network change (WatchPaths on
# the resolver/SystemConfiguration files) and once at load. Each fire runs a
# ~45s burst of snapshots. Logs: ~/Library/Logs/nextdns-captive-probe/
#
#   ./install-probe.sh            install + load
#   ./install-probe.sh uninstall  unload + remove the agent (logs are kept)

set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
PROBE="$SELF/bin/nextdns-lockdown-probe"
LABEL="com.nextdnslockdown.probe"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [ "${1:-install}" = "uninstall" ]; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "uninstalled (logs kept in ~/Library/Logs/nextdns-captive-probe/)"
    exit 0
fi

[ -f "$PROBE" ] || { echo "error: $PROBE not found" >&2; exit 1; }
chmod +x "$PROBE"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/nextdns-captive-probe"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PROBE</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>PROBE_TRIGGER</key><string>network-change</string></dict>
    <!-- Fire on network change: macOS rewrites these on join/DNS-config change. -->
    <key>WatchPaths</key>
    <array>
        <string>/etc/resolv.conf</string>
        <string>/var/run/resolv.conf</string>
        <string>/Library/Preferences/SystemConfiguration/preferences.plist</string>
        <string>/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist</string>
    </array>
    <!-- Also capture state once when the agent loads. -->
    <key>RunAtLoad</key>
    <true/>
    <!-- Don't pile up overlapping bursts; the script also single-flights. -->
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/nextdns-captive-probe/agent-stderr.log</string>
</dict>
</plist>
EOF

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true

echo "installed + loaded: $LABEL"
echo "  fires on every network change; ~45s burst each time."
echo "  logs:   ~/Library/Logs/nextdns-captive-probe/probe-\$(date +%F).log"
echo "  recent: $PROBE tail"
echo "  test:   $PROBE once"
