#!/bin/bash
# Re-bootstrap the baresip agent if it has been booted out of the console user's session.
# ponytail: 10s poll, not an event subscription. Fine — worst case is 10s of freedom.
LABEL=com.minh.forcecalls.endpoint
PLIST=/Library/LaunchAgents/$LABEL.plist
while :; do
  UID_=$(stat -f%u /dev/console)
  if [ "$UID_" -ge 500 ] 2>/dev/null; then
    launchctl print "gui/$UID_/$LABEL" >/dev/null 2>&1 \
      || launchctl bootstrap "gui/$UID_" "$PLIST" 2>/dev/null
  fi
  sleep 10
done
