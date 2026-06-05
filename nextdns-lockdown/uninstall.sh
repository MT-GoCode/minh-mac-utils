#!/bin/bash
#
# uninstall.sh — remove NextDNS Lockdown (root).
#   sudo ./uninstall.sh           # remove enforcement, daemon, binaries (keep config)
#   sudo ./uninstall.sh --purge   # also remove config + state dirs
#
set -uo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root:  sudo ./uninstall.sh" >&2; exit 1; }

LABEL="com.nextdnslockdown.enforcerd"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
ETC="/usr/local/etc/nextdns-lockdown"
APP="/Library/Application Support/NextDNSLockdown"

echo ">> disarming"
rm -f "$APP/armed" "$APP/travel-until"

echo ">> stopping daemon"
launchctl bootout system/"$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo ">> restoring default pf and disabling"
pfctl -f /etc/pf.conf 2>/dev/null || true
pfctl -d 2>/dev/null || true

echo ">> removing binaries"
rm -f /usr/local/bin/nextdns-lockdown /usr/local/bin/nextdns-lockdownd

if [ "${1:-}" = "--purge" ]; then
    echo ">> purging config + state"
    rm -rf "$ETC" "$APP"
fi

echo "Done. NextDNS itself is untouched; your resolver is still 127.0.0.1."
