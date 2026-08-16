#!/bin/bash
# Uninstall ALL minh-mac-utils tools (current + retired). Run: sudo ./scripts/uninstall-all.sh
# from your NORMAL shell (not a root shell).
#
# PRESERVES /Library/Application Support/Demonlock (your settings / policy / zones) and leaves the Paseo
# daemon wiring alone (that's your remote-agent host). Notes at the end tell you how to nuke those too.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $0"; exit 1; }
: "${SUDO_USER:?run via sudo from your normal user (need SUDO_USER)}"
[ "$SUDO_USER" != root ] || { echo "run as your normal user, not a root shell"; exit 1; }
U="$(id -u "$SUDO_USER")"; H="$(eval echo ~"$SUDO_USER")"

echo "==> stopping daemons/agents"
for a in com.demonlock.agent com.settingslock.watch com.minh.betterat com.user.fadedaemon com.wtalk.agent; do
  launchctl bootout "gui/$U/$a" 2>/dev/null || true
done
for d in com.demonlock.enforcerd com.settingslock.guard com.nextdnslockdown.enforcerd \
         com.nextdnslockdown.probe com.nextdns-discipline.delay-allow com.nextdns-sidecar.enforcerd; do
  launchctl bootout "system/$d" 2>/dev/null || true
done

echo "==> removing launchd plists (leaves the official nextdns.plist + Paseo)"
rm -f /Library/LaunchDaemons/com.demonlock.enforcerd.plist \
      /Library/LaunchDaemons/com.settingslock.guard.plist \
      /Library/LaunchDaemons/com.nextdnslockdown.*.plist \
      /Library/LaunchDaemons/com.nextdns-discipline.*.plist \
      /Library/LaunchDaemons/com.nextdns-sidecar.*.plist \
      /Library/LaunchAgents/com.demonlock.agent.plist \
      /Library/LaunchAgents/com.settingslock.watch.plist \
      /Library/LaunchAgents/com.wtalk.agent.plist
rm -f "$H/Library/LaunchAgents/com.minh.betterat.plist" \
      "$H/Library/LaunchAgents/com.user.fadedaemon.plist"

echo "==> removing apps"
rm -rf /Applications/Demonlock.app /Applications/RemoteAgentConnector.app \
       /Applications/msv2.app /Applications/stayup.app /Applications/wtalk.app

echo "==> removing CLIs"
rm -f /usr/local/bin/demonlock /usr/local/bin/msv2 /usr/local/bin/stayup \
      /usr/local/bin/rac /usr/local/bin/remote-agent-connector /usr/local/bin/wtalk \
      /usr/local/bin/nextdns-sidecar /usr/local/bin/settingslock /usr/local/bin/sudome \
      /usr/local/bin/nextdns-block /usr/local/bin/nextdns-allow /usr/local/bin/nextdns-delay-allow \
      /usr/local/bin/nextdns-test /usr/local/bin/nextdns-lockdown /usr/local/bin/nextdns-lockdownd
rm -f "$H/.local/bin/betterat" "$H/.local/bin/chrome-browser-fleet"

echo "==> removing config/support (NOT Demonlock settings)"
rm -rf /usr/local/etc/settingslock /usr/local/etc/sudome \
       /usr/local/etc/nextdns-discipline /usr/local/etc/nextdns-lockdown /usr/local/etc/nextdns-sidecar \
       "/Library/Application Support/NextDNSLockdown"

echo "==> removing sudoers grants"
rm -f /etc/sudoers.d/demonlock /etc/sudoers.d/stayup /etc/sudoers.d/sudome-* \
      /etc/sudoers.d/settingslock /etc/sudoers.d/nextdns-lockdown 2>/dev/null || true

echo
echo "✓ uninstalled."
echo "  PRESERVED (delete yourself if you want a clean slate):"
echo "    sudo rm -rf '/Library/Application Support/Demonlock'    # settings / policy / zones"
echo "  LEFT RUNNING: the Paseo daemon. To unwire it: ./scripts/unset-paseo-daemon.sh"
echo "  Residual pf rules from nextdns-lockdown clear on reboot."
