#!/bin/bash
# uninstall.sh — irreproachable. Refuses while goals are live: their watchers would keep prompting agents to run a
# clear that no longer exists. ~/.irreproachable is kept.
set -euo pipefail
BINDIR="${BINDIR:-$HOME/.local/bin}"
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
if [ -f "$BINDIR/irreproachable" ]; then
  out="$("$BINDIR/irreproachable" ls)"     # a failing ls aborts here (set -e): never remove blind
  live="$(printf '%s\n' "$out" | grep -E '^[0-9a-f]{8}  watching ' || true)"
  if [ -n "$live" ]; then
    bad "these goals are live; clear them first (irreproachable clear --agent <id>):"
    printf '%s\n' "$live" | sed 's/^/    /'
    exit 1
  fi
  rm -f "$BINDIR/irreproachable"; ok "removed $BINDIR/irreproachable"
else
  ok "nothing installed at $BINDIR/irreproachable"
fi
if grep -qs 'irreproachable paseo shim' "$BINDIR/paseo"; then
  rm -f "$BINDIR/paseo"; ok "removed the paseo shim install.sh wrote"
fi
[ -d "$HOME/.irreproachable" ] && printf '  \033[33m!\033[0m %s kept (goal logs)\n' "$HOME/.irreproachable" || true
