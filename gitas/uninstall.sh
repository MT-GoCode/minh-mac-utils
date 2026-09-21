#!/bin/bash
# uninstall.sh — gitas. Removes the CLI, the generated git config, and the include line.
# Leaves ~/.config/gitas/accounts.ini alone unless --purge-config (it holds your PATs).
set -euo pipefail
BINDIR="${BINDIR:-$HOME/.local/bin}"
GITDIR="$HOME/.config/git"
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }

git config --global --unset-all include.path "$GITDIR/gitas.inc" 2>/dev/null || true
rm -f  "$GITDIR/gitas.inc";  rm -rf "$GITDIR/gitas.d"; ok "removed generated git config"
rm -f  "$BINDIR/gitas";                                ok "removed $BINDIR/gitas"
if [ "${1:-}" = "--purge-config" ]; then
  rm -rf "$HOME/.config/gitas"; ok "removed ~/.config/gitas (PATs deleted)"
else
  ok "kept ~/.config/gitas/accounts.ini (use --purge-config to delete your PATs too)"
fi
echo "  note: git now has NO identity configured. Set one, or reinstall gitas."
