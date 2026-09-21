#!/bin/bash
# install.sh — gitas.
#   DEPLOYS the gitas CLI to ~/.local/bin (nothing runs from the checkout), installs your accounts
#   file to ~/.config/gitas/accounts.ini (0600), and FIRST purges every other git identity/credential
#   store on the machine so all auth goes through gitas. No sudo. macOS + Linux.
#
#   usage: ./install.sh <accounts.ini>       (or ./install.sh --keep-config to reuse the installed one)
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BINDIR="${BINDIR:-$HOME/.local/bin}"
CONF="$HOME/.config/gitas/accounts.ini"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }

[ "$(id -u)" -ne 0 ] || bad "do not run as root — gitas is a per-user tool"
[ -f "$SRC/gitas" ]  || bad "gitas missing from $SRC"
command -v git >/dev/null 2>&1 || bad "git not found"

ARG="${1:-}"
[ -n "$ARG" ] || bad "usage: ./install.sh <accounts.ini>   (see accounts.example.ini)"
if [ "$ARG" != "--keep-config" ]; then
  [ -f "$ARG" ] || bad "no such config file: $ARG"
fi

echo "gitas install"; echo

# ------------------------------------------------------------------ 1. purge everything else FIRST
"$SRC/gitas" purge

# ------------------------------------------------------------------ 2. config
mkdir -p "$(dirname "$CONF")"
if [ "$ARG" != "--keep-config" ]; then
  install -m 0600 "$ARG" "$CONF"
  ok "installed accounts → $CONF (0600)"
else
  [ -f "$CONF" ] || bad "--keep-config but no $CONF"
  chmod 600 "$CONF"; ok "reusing $CONF"
fi

# ------------------------------------------------------------------ 3. deploy CLI
mkdir -p "$BINDIR"
install -m 0755 "$SRC/gitas" "$BINDIR/gitas"
ok "deployed $BINDIR/gitas"
case ":$PATH:" in
  *":$BINDIR:"*) ok "$BINDIR is on PATH" ;;
  *) warn "$BINDIR is NOT on PATH — add:  export PATH=\"$BINDIR:\$PATH\"" ;;
esac

# ------------------------------------------------------------------ 4. generate git config
"$BINDIR/gitas" install

# ------------------------------------------------------------------ 5. verify
echo
echo "▸ verify"
"$BINDIR/gitas" list
echo
ok "done — 'gitas status' inside a repo shows which account applies"
