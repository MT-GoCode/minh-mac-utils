#!/usr/bin/env bash
# unset-paseo-daemon.sh — undo setup-paseo-daemon.sh: stop launchd owning the Paseo daemon and hand it
# back to the desktop app. Idempotent, safe to re-run. Run as YOU (no sudo).
#
#   1. bootout + remove the LaunchAgents sh.paseo.daemon and sh.paseo.refresh
#   2. flip manageBuiltInDaemon=true so the app spawns its own daemon again
#   3. stop the now-orphaned launchd daemon
set -euo pipefail

command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }
PASEO_BIN="$(command -v paseo || true)"; [ -n "$PASEO_BIN" ] || PASEO_BIN="$HOME/.local/bin/paseo"
SETTINGS="$HOME/Library/Application Support/Paseo/desktop-settings.json"
LA="$HOME/Library/LaunchAgents"
U="$(id -u)"

echo "==> removing LaunchAgents"
for label in sh.paseo.daemon sh.paseo.refresh; do
  launchctl bootout "gui/$U/$label" 2>/dev/null || true
  rm -f "$LA/$label.plist"
done

echo "==> desktop app: manage its own daemon again (manageBuiltInDaemon=true)"
if [ -f "$SETTINGS" ]; then
  tmp="$(mktemp)"
  jq '.settings.daemon.manageBuiltInDaemon = true' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
fi

echo "==> stopping the orphaned launchd daemon"
[ -x "$PASEO_BIN" ] && "$PASEO_BIN" daemon stop >/dev/null 2>&1 || true

echo "==> done: launchd no longer owns the Paseo daemon. Reopen Paseo to let it spawn its own."
