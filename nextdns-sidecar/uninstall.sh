#!/bin/bash
# uninstall.sh — remove nextdns-sidecar (root). Disarms + tears down pf, boots out the daemon, removes
# the binary, the nextdns-test shim, the launchd job, the pf ruleset, and runtime state. Credentials +
# config.json are KEPT unless you pass --purge.  Run:  sudo ./uninstall.sh [--purge]
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root:  sudo ./uninstall.sh" >&2; exit 1; }
PURGE=0; [ "${1:-}" = --purge ] && PURGE=1

ETC="/usr/local/etc/nextdns-sidecar"
APP="/Library/Application Support/NextDNSSidecar"
BIN="/usr/local/bin"
LABEL="com.minh.nextdns-sidecar.enforcerd"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

echo ">> disarming + tearing down pf"
rm -f "$APP/armed" 2>/dev/null || true
/sbin/pfctl -t local_dns -T flush >/dev/null 2>&1 || true
/sbin/pfctl -f /etc/pf.conf       >/dev/null 2>&1 || true
/sbin/pfctl -d                    >/dev/null 2>&1 || true

echo ">> booting out the daemon"
launchctl bootout system/"$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo ">> removing binary + nextdns-test shim"
rm -f "$BIN/nextdns-sidecar" "$BIN/nextdns-test"

echo ">> removing runtime state ($APP)"
rm -rf "$APP"

if [ "$PURGE" = 1 ]; then
    echo ">> --purge: removing config + credentials ($ETC)"
    rm -rf "$ETC"
else
    echo ">> removing pf ruleset (keeping credentials + config.json — pass --purge to remove them)"
    rm -f "$ETC/nextdns-lockdown.conf" "$ETC/doh-blocklist.txt" "$ETC/tor-dirauth.txt" "$ETC/local-dns.txt"
fi

echo
echo "✓ nextdns-sidecar uninstalled."
echo "  Installed configuration PROFILES are NOT removed (they're system-scoped). Remove them yourself"
echo "  in System Settings ▸ General ▸ Device Management:"
echo "    • NextDNS Encrypted-DNS  (the resolver)"
echo "    • Disable Browser DoH    (com.minh.nextdnslockdown.nobrowserdoh)"
