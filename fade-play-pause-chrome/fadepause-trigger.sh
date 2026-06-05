#!/usr/bin/env bash
# fadepause-trigger.sh — call on dictation START (or a hotkey). Requests PAUSE.
# Writes "pause <unique-token>" to the press file atomically (write temp + mv),
# so the daemon never sees a partial line. The token only needs to be unique per
# press; the daemon de-dupes on the whole line. We avoid `date +%N` because BSD
# date doesn't support it — $$ + $RANDOM is unique enough across presses.
PRESS_FILE="${FADEPAUSE_PRESS:-/tmp/fadepause.press}"
tmp="$(mktemp "${PRESS_FILE}.XXXXXX")" || exit 1
printf 'pause %s-%s-%s\n' "$(date +%s)" "$$" "$RANDOM$RANDOM" > "$tmp"
mv -f "$tmp" "$PRESS_FILE"
