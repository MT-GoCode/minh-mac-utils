#!/bin/bash
# Installer for `sudome` — the setuid-root grant/revoke-sudo gate.
# Run as root:  sudo ./install.sh
#
# Same model as nextdns-block: compile a C binary and install it mode 4711
# (setuid-root, execute-only for non-root) so the invoking user can run it but
# cannot read the baked-in password.
set -euo pipefail

PREFIX_BIN=/usr/local/bin
ETC_DIR=/usr/local/etc/sudome
CRED="$ETC_DIR/Allpassword"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SRC_DIR/sudome.c"

if [ "$(id -u)" -ne 0 ]; then
    echo "This installer must run as root. Re-run with: sudo $0 $*" >&2
    exit 1
fi
[ -f "$SRC" ] || { echo "error: source not found at $SRC" >&2; exit 1; }

# --- credentials (root-only) ---------------------------------------------
# Create the dir and an empty, locked-down password file if absent. An
# existing password is preserved (perms are re-asserted either way).
mkdir -p "$ETC_DIR"
chown root:wheel "$ETC_DIR"
chmod 700 "$ETC_DIR"
if [ ! -f "$CRED" ]; then
    umask 077
    : > "$CRED"
    echo "Created empty $CRED — set your password with: sudo nano $CRED"
fi
chown root:wheel "$CRED"
chmod 600 "$CRED"

# --- compile -------------------------------------------------------------
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
echo "Compiling..."
cc -O2 -Wall -o "$TMPD/sudome" "$SRC"

# --- install (nuke + reinstall) ------------------------------------------
rm -f "$PREFIX_BIN/sudome"
# setuid-root, execute-only for non-root (4711): user can run, can't read.
install -o root -g wheel -m 4711 "$TMPD/sudome" "$PREFIX_BIN/sudome"
chmod 4711 "$PREFIX_BIN/sudome"             # re-assert; guarantee setuid survived

echo "Installed:"
ls -l "$PREFIX_BIN/sudome"
echo
if [ ! -s "$CRED" ]; then
    echo "============================================================================"
    echo "  ⚠  NO PASSWORD SET YET — sudome will REFUSE to grant admin until you do:"
    echo
    echo "       sudo nano $CRED"
    echo
    echo "     Put your secret on the first line, save, and you're done."
    echo "============================================================================"
else
    echo "Password is set. To change it:  sudo nano $CRED"
fi
echo
echo "Usage:"
echo "  sudome add        # prompts for password, grants the invoking user admin/sudo"
echo "  sudome remove     # revokes it (no password)"
echo "Done."
