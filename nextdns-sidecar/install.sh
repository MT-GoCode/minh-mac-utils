#!/bin/bash
#
# install.sh — install nextdns-sidecar (root). Installs DISARMED; you arm explicitly.
#
# Merges the two source tools into ONE Swift binary + ONE root LaunchDaemon:
#   • NextDNS list manager  (block / add / delay-add / abort / future)   — was nextdns-discipline
#   • DNS-bypass pf lockdown (networklockdown arm / disarm / status)      — was nextdns-lockdown
#
# Safe by construction: validates the pf ruleset with `pfctl -n` before anything loads; does NOT enable
# pf or arm; does NOT install configuration profiles (it only CHECKS the Encrypted-DNS profile is present).
# Credentials are preserved across runs unless --reconfigure/--key-file.
#
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root:  sudo ./install.sh" >&2; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
ETC="/usr/local/etc/nextdns-sidecar"
APP="/Library/Application Support/NextDNSSidecar"
BIN="/usr/local/bin"
LABEL="com.nextdns-sidecar.enforcerd"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
CRED="$ETC/credentials"
CONFIG="$ETC/config.json"

RECONFIG=0; KEYFILE=""; PROFILE_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --reconfigure) RECONFIG=1 ;;
        --key-file) KEYFILE="${2:-}"; [ -n "$KEYFILE" ] || { echo "error: --key-file needs a path" >&2; exit 1; }; RECONFIG=1; shift ;;
        --profile)  PROFILE_ARG="${2:-}"; [ -n "$PROFILE_ARG" ] || { echo "error: --profile needs a value" >&2; exit 1; }; RECONFIG=1; shift ;;
        *) echo "error: unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

# The user who should own the marker inbox and be pinned as the enforced uid.
TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = root ]; then
    TARGET_USER="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
fi
[ -n "$TARGET_USER" ] && [ "$TARGET_USER" != root ] || { echo "error: cannot determine the non-root user (set SUDO_USER)"; exit 1; }
TARGET_UID="$(id -u "$TARGET_USER")"
echo ">> enforced user: $TARGET_USER (uid $TARGET_UID)"

# --- build ---------------------------------------------------------------
echo ">> building (swift build -c release)"
swift build -c release --package-path "$SRC"
BINARY="$SRC/.build/release/nextdns-sidecar"
[ -x "$BINARY" ] || { echo "error: build did not produce $BINARY" >&2; exit 1; }

# --- config dir + pf ruleset/tables (root-only) --------------------------
echo ">> config dir + pf files  ($ETC)"
install -d -o root -g wheel -m 700 "$ETC"
install -o root -g wheel -m 644 "$SRC/pf/nextdns-lockdown.conf" "$ETC/nextdns-lockdown.conf"
install -o root -g wheel -m 644 "$SRC/pf/doh-blocklist.txt"     "$ETC/doh-blocklist.txt"
install -o root -g wheel -m 644 "$SRC/pf/tor-dirauth.txt"       "$ETC/tor-dirauth.txt"
install -o root -g wheel -m 644 "$SRC/pf/local-dns.txt"         "$ETC/local-dns.txt"

# config.json (root, 0644): enforcedUser pins who may drop markers; delaySec is the delay-add delay.
if [ ! -f "$CONFIG" ]; then
    printf '{\n  "delaySec" : 43200,\n  "enforcedUser" : "%s"\n}\n' "$TARGET_UID" > "$CONFIG"
    chown root:wheel "$CONFIG"; chmod 644 "$CONFIG"
    echo ">> wrote $CONFIG (delay-add = 12h, enforcedUser = $TARGET_UID)"
else
    echo ">> kept existing $CONFIG"
fi

# --- credentials (root-only 0600) ----------------------------------------
if [ ! -f "$CRED" ] || [ "$RECONFIG" -eq 1 ]; then
    echo ">> NextDNS credentials -> $CRED (mode 600, root)."
    if [ -n "$PROFILE_ARG" ]; then PROFILE="$PROFILE_ARG"; else
        printf "NextDNS Profile ID (e.g. abc123): " > /dev/tty; read -r PROFILE < /dev/tty; fi
    if [ -n "$KEYFILE" ]; then
        [ -f "$KEYFILE" ] || { echo "error: key file not found: $KEYFILE" >&2; exit 1; }
        APIKEY="$(tr -d '\r\n' < "$KEYFILE")"
    else
        printf "NextDNS API key (input hidden): " > /dev/tty; read -rs APIKEY < /dev/tty; echo > /dev/tty; fi
    [ -n "$PROFILE" ] && [ -n "$APIKEY" ] || { echo "error: profile and API key are both required" >&2; exit 1; }
    umask 077; tmpc="$(mktemp)"
    printf 'PROFILE=%s\nAPI_KEY=%s\n' "$PROFILE" "$APIKEY" > "$tmpc"
    mv "$tmpc" "$CRED"; chown root:wheel "$CRED"; chmod 600 "$CRED"
    unset APIKEY PROFILE
    echo "   credentials saved."
else
    echo ">> kept existing credentials (use --reconfigure / --key-file to change)"
    chown root:wheel "$CRED"; chmod 600 "$CRED"
fi

# --- binary --------------------------------------------------------------
echo ">> binary  ($BIN/nextdns-sidecar)"
install -o root -g wheel -m 0755 "$BINARY" "$BIN/nextdns-sidecar"

# --- runtime state dir + USER-owned marker inbox -------------------------
echo ">> state dir  ($APP)"
install -d -o root -g wheel -m 755 "$APP"
# The inbox is USER-owned so `block`/`delay-add`/`abort`/`arm` can drop markers WITHOUT sudo. The daemon
# owner-checks every marker (MarkerIO: O_NOFOLLOW + st_uid == enforcedUID) before acting on it.
install -d -o "$TARGET_USER" -g staff -m 700 "$APP/inbox"

# --- validate pf ruleset (parse only, no load) ---------------------------
echo ">> validating pf ruleset (parse only)"
pfctl -n -f "$ETC/nextdns-lockdown.conf" || { echo "!! ruleset failed validation — aborting" >&2; exit 1; }
echo "   ruleset OK"

# --- launchd daemon (does pf enforcement + delayed applies + markers) ----
echo ">> launchd daemon"
install -o root -g wheel -m 644 "$SRC/launchd/${LABEL}.plist" "$PLIST"
launchctl bootout system/"$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

# --- CHECK the Encrypted-DNS profile (we do NOT install it) --------------
echo ">> Encrypted-DNS profile check"
if [ -f "/Library/Managed Preferences/com.apple.dnsSettings.managed.plist" ]; then
    echo "   DoH resolver profile:  installed"
else
    echo "   DoH resolver profile:  NOT installed"
    echo "   >> Install your NextDNS Encrypted-DNS .mobileconfig from https://apple.nextdns.io"
    echo "      (System Settings ▸ General ▸ Device Management). arm is REFUSED until it's present."
fi

cat <<EOF

Installed — currently DISARMED (nothing is blocked yet).

  nextdns-sidecar domains block instagram.com tiktok.com   # block (no sudo)
  sudo nextdns-sidecar domains add instagram.com           # allow now (sudo)
  nextdns-sidecar domains delay-add instagram.com          # allow in 12h (no sudo)
  nextdns-sidecar domains future                           # what's queued
  nextdns-sidecar networklockdown status                   # wall state
  nextdns-sidecar networklockdown arm                      # enforce (no sudo; needs the DoH profile)
  sudo nextdns-sidecar networklockdown disarm              # emergency off
EOF
