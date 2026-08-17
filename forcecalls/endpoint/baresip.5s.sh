#!/bin/bash
# SwiftBar plugin — menu bar status + mute toggle for baresip.
# Install: brew install --cask swiftbar; cp to ~/Library/Application Support/SwiftBar/
PATH=/opt/homebrew/bin:/usr/bin:/bin

cmd() {  # netstring-wrap a baresip command and send it
  local j="{\"command\":\"$1\"}"
  printf '%d:%s,' "${#j}" "$j" | nc -w1 127.0.0.1 4444 2>/dev/null
}

if ! pgrep -q baresip; then
  echo "☎️✗"; echo "---"; echo "baresip not running"; exit
fi

if cmd listcalls | grep -q 'ESTABLISHED'; then
  echo "☎️ on call"
  echo "---"
  echo "Mute / unmute | bash=$0 param1=mute terminal=false refresh=true"
else
  echo "☎️"
  echo "---"
  echo "Idle — registered"
fi
echo "Refresh | refresh=true"

[ "$1" = "mute" ] && cmd mute
