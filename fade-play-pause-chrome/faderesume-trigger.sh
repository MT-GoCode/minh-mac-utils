#!/usr/bin/env bash
# faderesume-trigger.sh — call on dictation STOP (or a hotkey). Requests RESUME.
# Atomic write + unique token, same rationale as fadepause-trigger.sh.
PRESS_FILE="${FADEPAUSE_PRESS:-/tmp/fadepause.press}"
tmp="$(mktemp "${PRESS_FILE}.XXXXXX")" || exit 1
printf 'resume %s-%s-%s\n' "$(date +%s)" "$$" "$RANDOM$RANDOM" > "$tmp"
mv -f "$tmp" "$PRESS_FILE"
