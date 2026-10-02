#!/bin/bash
# uninstall.sh — pacemaker. Removes the CLI. Leaves ~/.pacemaker alone: those are your
# job logs, and a run may still be going.
set -euo pipefail
BINDIR="${BINDIR:-$HOME/.local/bin}"
if [ -f "$BINDIR/pacemaker" ]; then
  rm -f "$BINDIR/pacemaker"; printf '  \033[32m✓\033[0m removed %s\n' "$BINDIR/pacemaker"
else
  printf '  \033[32m✓\033[0m nothing installed at %s\n' "$BINDIR/pacemaker"
fi
[ -d "$HOME/.pacemaker" ] && printf '  \033[33m!\033[0m %s kept (job logs; delete by hand if you want)\n' "$HOME/.pacemaker" || true
