#!/bin/bash
# uninstall.sh — the exact reverse of install.sh. Leaves the checkout and the extension alone.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.minh.browser-blitz"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$HOME/.local/state/browser-blitz"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

echo "browser-blitz uninstall"; echo
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && ok "LaunchAgent stopped" || ok "LaunchAgent was not loaded"
# Also kill a hand-started shim, or it keeps :9334/:9342 and the socket after uninstall.
pkill -f "$HERE/shim.js" 2>/dev/null && ok "stopped a stray shim" || true
[ -f "$PLIST" ] && rm -f "$PLIST" && ok "removed $PLIST" || ok "no LaunchAgent plist to remove"

# Search the same places install.sh could have written to, including a custom BINDIR it recorded.
# And remove ONLY our own symlink: `bb` is also a Homebrew formula name, and the old blanket
# `[ -L ] && rm` would have deleted somebody else's.
DIRS="/opt/homebrew/bin /usr/local/bin"
[ -f "$STATE/bindir" ] && DIRS="$DIRS $(cat "$STATE/bindir")"
command -v brew >/dev/null 2>&1 && DIRS="$DIRS $(brew --prefix)/bin"
for d in $(printf '%s\n' $DIRS | sort -u); do
  for n in browser-blitz bb; do
    [ -L "$d/$n" ] || continue
    if [ "$(readlink "$d/$n")" = "$HERE/browser-blitz" ]; then
      rm -f "$d/$n" && ok "removed $d/$n"
      [ -e "$d/$n.before-browser-blitz" ] && mv "$d/$n.before-browser-blitz" "$d/$n" && ok "restored the $n that was there before"
    else
      warn "left $d/$n alone — it does not point at this checkout"
    fi
  done
done

if [ "${1:-}" = "--purge" ]; then rm -rf "$STATE" && ok "removed $STATE"
else ok "kept $STATE (sessions, mappings, logs) — re-run with --purge to delete"
fi
echo
echo "remove the extension by hand at chrome://extensions if you want it gone."
echo "playwright-cli was installed globally by install.sh and is left in place:"
echo "  npm uninstall -g @playwright/cli    # if you want that gone too"
