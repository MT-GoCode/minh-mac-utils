#!/bin/bash
# install.sh — monitor-heartbeat.
#   Deploys the monitor-heartbeat CLI to ~/.local/bin. Nothing runs from the checkout,
#   nothing is configured, no daemon, no sudo. macOS + Linux.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
BINDIR="${BINDIR:-$HOME/.local/bin}"
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }

[ "$(id -u)" -ne 0 ] || bad "do not run as root — monitor-heartbeat is a per-user tool"
[ -f "$SRC/monitor-heartbeat" ] || bad "monitor-heartbeat missing from $SRC"
sh -n "$SRC/monitor-heartbeat" || bad "monitor-heartbeat does not parse"

mkdir -p "$BINDIR"
install -m 0755 "$SRC/monitor-heartbeat" "$BINDIR/monitor-heartbeat"
ok "$BINDIR/monitor-heartbeat"

case ":$PATH:" in
  *":$BINDIR:"*) ok "$BINDIR is on PATH" ;;
  *) printf '  \033[33m!\033[0m %s is not on PATH — add it to your shell rc\n' "$BINDIR" ;;
esac
"$BINDIR/monitor-heartbeat" --help >/dev/null || bad "installed copy will not run"
ok "runs"
