#!/bin/bash
# uninstall.sh — monitor-heartbeat. Removes the CLI. There is nothing else to remove:
# no config, no daemon, no state. Job logs are the caller's files and are left alone.
set -euo pipefail
BINDIR="${BINDIR:-$HOME/.local/bin}"
if [ -f "$BINDIR/monitor-heartbeat" ]; then
  rm -f "$BINDIR/monitor-heartbeat"; printf '  \033[32m✓\033[0m removed %s\n' "$BINDIR/monitor-heartbeat"
else
  printf '  \033[32m✓\033[0m nothing installed at %s\n' "$BINDIR/monitor-heartbeat"
fi
