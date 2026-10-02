#!/bin/bash
# install.sh — pacemaker. One file to ~/.local/bin. No sudo, no daemon, no config.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
BINDIR="${BINDIR:-$HOME/.local/bin}"
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }

[ "$(id -u)" -ne 0 ] || bad "do not run as root — pacemaker is a per-user tool"
[ -f "$SRC/pacemaker" ] || bad "pacemaker missing from $SRC"
command -v python3 >/dev/null || bad "python3 not found"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SRC/pacemaker" || bad "pacemaker does not parse"

mkdir -p "$BINDIR"
install -m 0755 "$SRC/pacemaker" "$BINDIR/pacemaker"
ok "$BINDIR/pacemaker"
case ":$PATH:" in
  *":$BINDIR:"*) ok "$BINDIR is on PATH" ;;
  *) printf '  \033[33m!\033[0m %s is not on PATH — add it to your shell rc\n' "$BINDIR" ;;
esac
"$BINDIR/pacemaker" --help >/dev/null || bad "the installed copy will not run"
ok "runs — now ./test.sh to check it behaves correctly on this machine"
