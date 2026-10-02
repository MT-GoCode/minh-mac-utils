#!/bin/bash
# uninstall.sh — pacemaker. Removes the CLI. Leaves ~/.pacemaker alone: those are your
# job logs, and a run may still be going.
set -euo pipefail
BINDIR="${BINDIR:-$HOME/.local/bin}"
if [ -f "$BINDIR/pacemaker" ]; then
  # Ask it before deleting it: once the CLI is gone there is no way to --attach to a job
  # that is still running, and the job itself keeps going regardless.
  live="$("$BINDIR/pacemaker" --list 2>/dev/null | grep RUNNING || true)"
  rm -f "$BINDIR/pacemaker"; printf '  \033[32m✓\033[0m removed %s\n' "$BINDIR/pacemaker"
  if [ -n "$live" ]; then
    printf '  \033[33m!\033[0m these are still running and can no longer be attached to:\n'
    printf '%s\n' "$live" | sed 's/^/    /'
  fi
else
  printf '  \033[32m✓\033[0m nothing installed at %s\n' "$BINDIR/pacemaker"
fi
[ -d "$HOME/.pacemaker" ] && printf '  \033[33m!\033[0m %s kept (job logs; delete by hand if you want)\n' "$HOME/.pacemaker" || true
