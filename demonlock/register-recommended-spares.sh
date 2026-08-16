#!/bin/bash
# register-recommended-spares.sh — register the third-party menubar utilities that have NO installer in
# this repo (keyboard remapper, launcher, etc.) as demonlock spares, so a lockout doesn't kill them.
#
# demonlock ships with NO base spare list except itself — every other app is registered dynamically.
# Your own apps (msv2/stayup/wtalk/remote-agent-connector) self-register from their own installers; this
# script is the curated add-on set for the third-party apps that can't. Run once after installing
# demonlock (and again if you ever wipe demonlock's settings, which drops dynamic registrations).
#
#   sudo ./demonlock/register-recommended-spares.sh
#
# Each is registered via `demonlock safe-apps register` (IMMEDIATE, requires root). All are third-party
# Developer-ID apps → --no-root-ownership (Regime B: Apple-anchored + their Team ID, our key can't forge).
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root:  sudo $0" >&2; exit 1; }
DL=/Applications/Demonlock.app/Contents/MacOS/demonlock
[ -x "$DL" ] || { echo "demonlock not installed — install it first, then re-run." >&2; exit 1; }

# name | bundle id | Apple Team ID
apps=(
  "alttab|com.lwouis.alt-tab-macos|QXD7GW8FHY"
  "raycast|com.raycast.macos|SY64MV22J9"
  "shottr|cc.ffitch.shottr|2Y683PRQWN"
  "amphetamine|com.if.Amphetamine|U5SR49N3PT"
  "betterdisplay|pro.betterdisplay.BetterDisplay|299YSU96J7"
  "scroll-reverser|com.pilotmoon.scroll-reverser|6W6K75YWQ9"
  "karabiner-core|org.pqrs.Karabiner-Core-Service|G43BCU2T37"
  "karabiner-menu|org.pqrs.Karabiner-Menu|G43BCU2T37"
  "karabiner-notify|org.pqrs.Karabiner-NotificationWindow|G43BCU2T37"
)
fail=0
for e in "${apps[@]}"; do
  IFS='|' read -r name bid tid <<<"$e"
  if "$DL" safe-apps register --name "$name" --bid "$bid" --tid "$tid" --no-root-ownership; then
    echo "  ✓ $name"
  else
    echo "  ✗ $name (register failed)"; fail=1
  fi
done
echo
"$DL" safe-apps show || true
[ "$fail" = 0 ] && echo "✓ recommended third-party spares registered." || echo "⚠️  some registrations failed (see above)."
