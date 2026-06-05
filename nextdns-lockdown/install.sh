#!/bin/bash
#
# install.sh — install NextDNS Lockdown (root). Installs DISARMED; you arm explicitly.
#
# Safe by construction:
#   * validates the pf ruleset with `pfctl -n` BEFORE anything is loaded
#   * does NOT enable pf or arm enforcement (you run `sudo nextdns-lockdown arm`)
#   * never touches general web traffic; loopback (NextDNS path) is exempt
#
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root:  sudo ./install.sh" >&2; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
ETC="/usr/local/etc/nextdns-lockdown"
APP="/Library/Application Support/NextDNSLockdown"
BIN="/usr/local/bin"
LABEL="com.nextdnslockdown.enforcerd"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

echo ">> config dir + tables  ($ETC)"
install -d -o root -g wheel -m 700 "$ETC"
install -o root -g wheel -m 644 "$SRC/pf/nextdns-lockdown.conf" "$ETC/nextdns-lockdown.conf"
install -o root -g wheel -m 644 "$SRC/pf/doh-blocklist.txt"     "$ETC/doh-blocklist.txt"
install -o root -g wheel -m 644 "$SRC/pf/tor-dirauth.txt"       "$ETC/tor-dirauth.txt"
[ -f "$ETC/dns-allow.txt" ] || install -o root -g wheel -m 644 /dev/null "$ETC/dns-allow.txt"

echo ">> state dir  ($APP)"
install -d -o root -g wheel -m 755 "$APP"

echo ">> binaries"
install -o root -g wheel -m 0755 "$SRC/bin/nextdns-lockdown"  "$BIN/nextdns-lockdown"
install -o root -g wheel -m 0700 "$SRC/bin/nextdns-lockdownd" "$BIN/nextdns-lockdownd"

echo ">> validating pf ruleset (parse only, no load)"
if ! pfctl -n -f "$ETC/nextdns-lockdown.conf"; then
    echo "!! ruleset failed validation — aborting, nothing was enabled." >&2
    exit 1
fi
echo "   ruleset OK"

echo ">> launchd daemon"
install -o root -g wheel -m 644 "$SRC/launchd/${LABEL}.plist" "$PLIST"
launchctl bootout system/"$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

echo
echo "Installed — currently DISARMED (nothing is being blocked yet)."
echo
echo "Recommended next steps:"
echo "  1) nextdns-lockdown selftest      # should show bypasses OPEN"
echo "  2) sudo nextdns-lockdown arm       # turn enforcement on"
echo "  3) nextdns-lockdown selftest      # should show bypasses CLOSED"
echo "  4) open Chrome and confirm normal sites still load"
echo
echo "Travelling / captive portal:  sudo nextdns-lockdown travel 15"
echo "Emergency off:                sudo nextdns-lockdown disarm"
