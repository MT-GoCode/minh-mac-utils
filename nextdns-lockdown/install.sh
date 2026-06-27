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
install -o root -g wheel -m 644 "$SRC/pf/local-dns.txt"         "$ETC/local-dns.txt"
# Cache the Encrypted-DNS profile so the daemon can re-assert it if it is removed.
[ -f "$SRC/profiles/NextDNS-hardened.mobileconfig" ] && \
  install -o root -g wheel -m 644 "$SRC/profiles/NextDNS-hardened.mobileconfig" "$ETC/profile.mobileconfig"

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

echo ">> configuration profiles  (you must approve these — macOS can't script it)"
# A hand-authored profile cannot be installed silently from the CLI; it must be
# approved in System Settings. And `open` only surfaces the prompt from YOUR GUI
# session — not from this root script. So we just detect what's missing and print
# the exact commands for you to run in your own shell.
dns_profile_installed()     { [ -f "/Library/Managed Preferences/com.apple.dnsSettings.managed.plist" ]; }
browser_profile_installed() { profiles show 2>/dev/null | grep -q 'com.minh.nextdnslockdown.nobrowserdoh'; }
NEED_DNS=0; NEED_BROWSER=0
if dns_profile_installed; then echo "   DoH resolver profile:  already installed"
else echo "   DoH resolver profile:  NOT installed"; NEED_DNS=1; fi
if browser_profile_installed; then echo "   browser-DoH profile:   already installed"
else echo "   browser-DoH profile:   NOT installed"; NEED_BROWSER=1; fi

echo
echo "Installed — currently DISARMED (nothing is being blocked yet)."
echo
if [ "$NEED_DNS" = 1 ] || [ "$NEED_BROWSER" = 1 ]; then
    echo "  >> ACTION NEEDED — install the missing profile(s). Run each line below in"
    echo "     YOUR OWN shell (NOT sudo), one at a time; after each 'open', click"
    echo "     'Profile Downloaded' at the TOP of the System Settings sidebar -> Install:"
    echo
    [ "$NEED_DNS" = 1 ]     && echo "       open \"$SRC/profiles/NextDNS-hardened.mobileconfig\""
    [ "$NEED_BROWSER" = 1 ] && echo "       open \"$SRC/profiles/no-browser-doh.mobileconfig\""
    echo
fi
echo "Then:"
echo "  nextdns-lockdown selftest          # disarmed -> bypasses OPEN, profiles PASS"
echo "  sudo nextdns-lockdown arm           # enforcement on (needs the DoH profile)"
echo "  nextdns-lockdown selftest           # armed -> bypasses CLOSED"
echo
echo "Captive portals work automatically — there is NO travel mode."
echo "Emergency off:  sudo nextdns-lockdown disarm"
