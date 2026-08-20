#!/bin/bash
# uninstall.sh — the exact reverse of install.sh. Leaves the checkout and the extension alone.
set -euo pipefail
LABEL="com.minh.browser-blitz"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$HOME/.local/state/browser-blitz"
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }

echo "browser-blitz uninstall"; echo
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && ok "LaunchAgent stopped" || ok "LaunchAgent was not loaded"
rm -f "$PLIST" && ok "removed $PLIST"

for d in /opt/homebrew/bin /usr/local/bin; do
  for n in browser-blitz bb; do
    [ -L "$d/$n" ] && rm -f "$d/$n" && ok "removed $d/$n"
  done
done

if [ "${1:-}" = "--purge" ]; then rm -rf "$STATE" && ok "removed $STATE"
else ok "kept $STATE (sessions, mappings, logs) — re-run with --purge to delete"
fi
echo
echo "remove the extension by hand at chrome://extensions if you want it gone."
