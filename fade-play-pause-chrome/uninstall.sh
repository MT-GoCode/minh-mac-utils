#!/usr/bin/env bash
PLIST_DST="$HOME/Library/LaunchAgents/com.user.fadedaemon.plist"
launchctl unload "$PLIST_DST" 2>/dev/null || true
rm -f "$PLIST_DST"
rm -f "$HOME/.local/bin/fadepause" "$HOME/.local/bin/faderesume"
echo "Unloaded and removed com.user.fadedaemon (and the fadepause/faderesume launchers)"
