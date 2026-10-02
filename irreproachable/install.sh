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
SHIM="irreproachable paseo shim"
grep -qs "$SHIM" "$BINDIR/paseo" && rm -f "$BINDIR/paseo" && hash -r   # re-derive it: never probe through an old shim
command -v paseo >/dev/null || bad "paseo not on PATH — irreproachable drives agents through it"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SRC/irreproachable" || bad "irreproachable does not parse"

# A live watcher runs the old code: a newer mute would poke it with a signal it does not handle, killing it.
if [ -x "$BINDIR/irreproachable" ]; then
  out="$("$BINDIR/irreproachable" ls)"     # a failing ls aborts here (set -e): never replace blind
  live="$(printf '%s\n' "$out" | grep -E '^[0-9a-f]{8}  watching ' || true)"
  if [ -n "$live" ]; then
    printf '%s\n' "$live" | sed 's/^/    /'
    bad "these goals are live; clear them first (irreproachable clear --agent <id>)"
  fi
fi

mkdir -p "$BINDIR"
install -m 0755 "$SRC/irreproachable" "$BINDIR/irreproachable"

# Agents' shells get a plain PATH, not a login one. If paseo is only reachable from a login shell (an nvm
# install on macOS), give agents a shim that calls the exact node and paseo found now.
if ! PATH="$BINDIR:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" command -v paseo >/dev/null; then
  PASEO="$(command -v paseo)"; NODE="$(command -v node)" || bad "node not found, so the paseo shim cannot be written"
  printf '#!/bin/sh\n# %s -- re-run irreproachable/install.sh if node moves\nexec "%s" "%s" "$@"\n' \
    "$SHIM" "$NODE" "$PASEO" > "$BINDIR/paseo"
  chmod 0755 "$BINDIR/paseo"
  ok "$BINDIR/paseo (shim: agents cannot see $PASEO)"
fi
ok "$BINDIR/irreproachable"
case ":$PATH:" in
  *":$BINDIR:"*) ok "$BINDIR is on PATH" ;;
  *) printf '  \033[33m!\033[0m %s is not on PATH — add it to your shell rc\n' "$BINDIR" ;;
esac
"$BINDIR/irreproachable" --help >/dev/null || bad "the installed copy will not run"
ok "runs — now 'irreproachable --selftest' to check it behaves correctly on this machine"
