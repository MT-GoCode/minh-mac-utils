#!/bin/bash
# install.sh — irreproachable. One file to ~/.local/bin. No sudo, no daemon, no config.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
BINDIR="${BINDIR:-$HOME/.local/bin}"
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }

[ "$(id -u)" -ne 0 ] || bad "do not run as root — irreproachable is a per-user tool"
[ -f "$SRC/irreproachable" ] || bad "irreproachable missing from $SRC"
command -v python3 >/dev/null || bad "python3 not found"
command -v paseo >/dev/null || bad "paseo not on PATH — irreproachable drives agents through it"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SRC/irreproachable" || bad "irreproachable does not parse"

mkdir -p "$BINDIR"
install -m 0755 "$SRC/irreproachable" "$BINDIR/irreproachable"
ok "$BINDIR/irreproachable"
case ":$PATH:" in
  *":$BINDIR:"*) ok "$BINDIR is on PATH" ;;
  *) printf '  \033[33m!\033[0m %s is not on PATH — add it to your shell rc\n' "$BINDIR" ;;
esac
"$BINDIR/irreproachable" --help >/dev/null || bad "the installed copy will not run"
ok "runs — now 'irreproachable --selftest' to check it behaves correctly on this machine"
