#!/usr/bin/env bash
# paseo-refresh.sh — called nightly by LaunchAgent sh.paseo.refresh.
# The Paseo app auto-updates itself (ShipIt); the launchd daemon runs the
# app-bundled CLI, so after an app update the running daemon is stale.
# Detect that (on-disk cliVersion != running daemonVersion) and restart the
# daemon via launchd — but never while an agent is actively running.
set -euo pipefail

PASEO="${PASEO_BIN:-$HOME/.local/bin/paseo}"
U="$(id -u)"

command -v jq >/dev/null || { echo "$(date): jq missing — cannot compare versions, skipping" >&2; exit 1; }

st="$("$PASEO" --json daemon status 2>/dev/null || true)"
if [ -z "$st" ]; then
  echo "$(date): daemon not reachable — kickstarting"
  launchctl kickstart "gui/$U/sh.paseo.daemon" 2>/dev/null || true
  exit 0
fi

cli="$(jq -r .cliVersion <<<"$st")"
dae="$(jq -r .daemonVersion <<<"$st")"
if [ "$cli" = "$dae" ]; then
  exit 0
fi

running="$("$PASEO" --json ls 2>/dev/null | jq -r '[.[] | select(.status=="running")] | length' || echo 0)"
if [ "${running:-0}" != "0" ]; then
  echo "$(date): update pending ($dae -> $cli) but $running agent(s) running — deferring"
  exit 0
fi

echo "$(date): restarting daemon $dae -> $cli"
launchctl kickstart -k "gui/$U/sh.paseo.daemon"
