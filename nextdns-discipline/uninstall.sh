#!/bin/bash
# Remove the nextdns-allow / nextdns-block tools.
# Run as root: sudo ./uninstall.sh   (add --purge to also delete saved credentials)
set -euo pipefail

PREFIX_BIN=/usr/local/bin
ETC_DIR=/usr/local/etc/nextdns-discipline

if [ "$(id -u)" -ne 0 ]; then
    echo "Must run as root: sudo $0 $*" >&2
    exit 1
fi

# Stop + remove the delayed-allow applier daemon first.
DAEMON_PLIST="/Library/LaunchDaemons/com.nextdns-discipline.delay-allow.plist"
launchctl bootout system "$DAEMON_PLIST" 2>/dev/null || true
rm -f "$DAEMON_PLIST"

rm -f "$PREFIX_BIN/nextdns-block" "$PREFIX_BIN/nextdns-allow" "$PREFIX_BIN/nextdns-delay-allow" "$PREFIX_BIN/nextdns-test"
echo "Removed binaries + applier daemon."

if [ "${1:-}" = "--purge" ]; then
    rm -rf "$ETC_DIR"
    echo "Purged credentials + delayed-allow queue ($ETC_DIR)."
else
    echo "Kept credentials + queue in $ETC_DIR (use --purge to delete)."
fi
