#!/bin/bash
# Installer for the nextdns-allow / nextdns-block self-discipline tools.
# Run as root:  sudo ./install.sh   (use `sudo ./install.sh --reconfigure` to re-enter credentials)
#
# Follows the nuke-and-reinstall rule: the binaries are always rebuilt and
# reinstalled fresh. Credentials are preserved across runs unless --reconfigure.
set -euo pipefail

PREFIX_BIN=/usr/local/bin
ETC_DIR=/usr/local/etc/nextdns-discipline
CRED="$ETC_DIR/credentials"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SRC_DIR/nextdns_discipline.c"

if [ "$(id -u)" -ne 0 ]; then
    echo "This installer must run as root. Re-run with: sudo $0 $*" >&2
    exit 1
fi
[ -f "$SRC" ] || { echo "error: source not found at $SRC" >&2; exit 1; }

RECONFIG=0
KEYFILE=""
PROFILE_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --reconfigure) RECONFIG=1 ;;
        --key-file) KEYFILE="${2:-}"; [ -n "$KEYFILE" ] || { echo "error: --key-file needs a path" >&2; exit 1; }; RECONFIG=1; shift ;;
        --profile)  PROFILE_ARG="${2:-}"; [ -n "$PROFILE_ARG" ] || { echo "error: --profile needs a value" >&2; exit 1; }; RECONFIG=1; shift ;;
        *) echo "error: unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

# --- credentials (root-only) ---------------------------------------------
mkdir -p "$ETC_DIR"
chown root:wheel "$ETC_DIR"
chmod 700 "$ETC_DIR"

if [ ! -f "$CRED" ] || [ "$RECONFIG" -eq 1 ]; then
    echo "Configuring NextDNS credentials -> $CRED (mode 600, root)."

    # Profile ID is not secret: take from --profile, else prompt.
    if [ -n "$PROFILE_ARG" ]; then
        PROFILE="$PROFILE_ARG"
    else
        printf "NextDNS Profile ID (e.g. abc123): " > /dev/tty
        read -r PROFILE < /dev/tty
    fi

    # API key: read from --key-file (never echoed) or via a hidden prompt.
    if [ -n "$KEYFILE" ]; then
        [ -f "$KEYFILE" ] || { echo "error: key file not found: $KEYFILE" >&2; exit 1; }
        APIKEY="$(tr -d '\r\n' < "$KEYFILE")"   # strip trailing newline(s)
    else
        printf "NextDNS API key (input hidden): " > /dev/tty
        read -rs APIKEY < /dev/tty
        echo > /dev/tty
    fi

    if [ -z "$PROFILE" ] || [ -z "$APIKEY" ]; then
        echo "error: profile and API key are both required" >&2
        exit 1
    fi
    umask 077
    tmpc="$(mktemp)"
    printf 'PROFILE=%s\nAPI_KEY=%s\n' "$PROFILE" "$APIKEY" > "$tmpc"
    mv "$tmpc" "$CRED"
    chown root:wheel "$CRED"
    chmod 600 "$CRED"
    unset APIKEY PROFILE
    echo "Credentials saved."
else
    echo "Existing credentials kept (use --reconfigure or --key-file to change)."
    chown root:wheel "$CRED"
    chmod 600 "$CRED"
fi

# --- compile (no libcurl; the binaries shell out to /usr/bin/curl) --------
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
echo "Compiling..."
cc -O2 -Wall -DMODE_BLOCK -o "$TMPD/nextdns-block" "$SRC"
cc -O2 -Wall -DMODE_ALLOW -o "$TMPD/nextdns-allow" "$SRC"

# --- install (nuke + reinstall) ------------------------------------------
rm -f "$PREFIX_BIN/nextdns-block" "$PREFIX_BIN/nextdns-allow" "$PREFIX_BIN/nextdns-test"

# block: setuid-root, execute-only for non-root (4711) -> user can run, can't read.
install -o root -g wheel -m 4711 "$TMPD/nextdns-block" "$PREFIX_BIN/nextdns-block"
# allow: root-only, not setuid -> only usable via sudo.
install -o root -g wheel -m 0700 "$TMPD/nextdns-allow" "$PREFIX_BIN/nextdns-allow"
# test: plain script, user-runnable, no secrets (just dig).
install -o root -g wheel -m 0755 "$SRC_DIR/nextdns-test" "$PREFIX_BIN/nextdns-test"

# Re-assert modes explicitly (guarantee the setuid bit survived).
chmod 4711 "$PREFIX_BIN/nextdns-block"
chmod 0700 "$PREFIX_BIN/nextdns-allow"
chmod 0755 "$PREFIX_BIN/nextdns-test"

echo "Installed:"
ls -l "$PREFIX_BIN/nextdns-block" "$PREFIX_BIN/nextdns-allow" "$PREFIX_BIN/nextdns-test"
echo
echo "Done."
echo "  nextdns-block instagram.com tiktok.com       # user-runnable"
echo "  sudo nextdns-allow instagram.com             # sudo-gated"
echo "  nextdns-test instagram.com                   # check if actually blocked"
