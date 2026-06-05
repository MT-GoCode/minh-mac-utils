#!/usr/bin/env bash
#
# fadedaemon.sh — long-running worker that fades + pauses / resumes media in
# Chromium browsers (Google Chrome, Microsoft Edge, ...) on request.
#
# Triggers (dictation start/stop, a hotkey, ...) write a line to PRESS_FILE:
#   "pause <token>"  -> fade out + pause every playing, non-meeting tab; record
#                       "<app>\t<tabId>\t<url>" for each so it can be restored.
#   "resume <token>" -> fade in + play exactly the recorded tabs (matched by tab
#                       id, so it survives track changes / tab reordering), then
#                       clear the record.
# <token> only needs to be unique per press; the daemon de-dupes on the whole
# line so it never acts on the same press twice.
#
# Robustness — built to survive long uptime, sleep/wake/lock, reboots, hundreds
# of tabs, suspended/discarded/wedged tabs, and stale files:
#   * Every Apple Event is bounded by `with timeout` + `try`, so a slept, tab-
#     suspended, or wedged tab can never hang the daemon or abort a scan — it is
#     skipped, and partial results are still used.
#   * Tab work runs in parallel (capped at MAX_PARALLEL), so many/slept tabs do
#     not serialize into multi-second stalls.
#   * Startup hygiene: kills orphaned older instances, ignores any stale press
#     left from before startup, discards stale pause state, trims a huge log.
#   * Startup self-check logs actionable diagnostics (missing Automation
#     permission, "Allow JavaScript from Apple Events" off, browser not running).
#   * Only the daemon spawns osascript, so the lightweight triggers need no
#     Automation permission.
#
# NOTE: the AppleScript borrows Google Chrome's scripting terminology (`using
# terms from application "Google Chrome"`) so it can drive each browser by a
# variable name. Chrome must stay installed even if you only use Edge; change
# every "Google Chrome" donor reference below if you drop Chrome.

PRESS_FILE="${FADEPAUSE_PRESS:-/tmp/fadepause.press}"
STATE_FILE="${FADEPAUSE_STATE:-/tmp/fadepause.state}"
LOG_FILE="${FADEPAUSE_LOG:-$HOME/Library/Logs/fadedaemon.log}"
POLL_S="${FADEPAUSE_POLL:-0.02}"
BROWSERS=("Google Chrome" "Microsoft Edge")
MAX_PARALLEL="${FADEPAUSE_MAX_PARALLEL:-32}"   # cap concurrent osascript workers
LOG_MAX_BYTES="${FADEPAUSE_LOG_MAX:-1048576}"  # trim log in place if larger than this
# Per-Apple-Event timeouts (seconds) are hardcoded as literals in the AppleScript
# below: 2s for a single tab's execute-javascript, 4s for listing a browser.

TAB=$'\t'
last_handled=""

log() { printf '%s [daemon] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# ---------------------------------------------------------------------------
# AppleScript helpers. Each is self-contained, guards "is running", borrows
# Chrome's terminology, and bounds every browser interaction with a timeout so
# it can never hang. App name / ids / urls are passed as argv (never spliced
# into the script text).
# ---------------------------------------------------------------------------

# fused_scan <app> — the whole pause pass in ONE osascript (the fast path):
# batch-fetch URL/loading/id per window (cheap; does NOT wake suspended/slept
# tabs and filters chrome-extension:// suspender placeholders for free), then for
# each loaded, http(s), non-meeting tab fire ONE detect+fade+pause JS. The fade
# starts in-page the instant the playing tab is reached — no second round trip.
# Each tab's JS is bounded by `with timeout` + `try`, so a slept/wedged tab is
# skipped (never hangs / aborts). Appends "<app>\t<tabId>\t<url>" per paused tab.
# do_pause runs this for both browsers in parallel, so press->fade ~= one
# osascript (~150-200ms), matching the native media key.
fused_scan() {
  local app="$1" out
  out=$(osascript - "$app" <<'OSA' 2>/dev/null
on run argv
set appName to item 1 of argv
set TS to (character id 9)
set out to ""
using terms from application "Google Chrome"
  try
    with timeout of 6 seconds
      if application appName is running then
        tell application appName
          repeat with wi from 1 to count of windows
            set us to URL of tabs of window wi
            set ds to loading of tabs of window wi
            set idl to id of tabs of window wi
            repeat with ti from 1 to count of us
              set u to item ti of us
              if u starts with "http" and (item ti of ds) is false then
                if u does not contain "meet.google.com" and u does not contain "zoom.us" and u does not contain "zoom.com" and u does not contain "teams.microsoft.com" and u does not contain "teams.live.com" and u does not contain "discord.com" and u does not contain "slack.com" and u does not contain "webex.com" and u does not contain "whereby.com" and u does not contain "jit.si" and u does not contain "around.co" and u does not contain "gather.town" and u does not contain "chime.aws" and u does not contain "8x8.vc" then
                  set didit to "0"
                  try
                    with timeout of 2 seconds
                      if u contains "open.spotify.com" then
                        tell (tab ti of window wi) to set didit to execute javascript "(function(){var b=document.querySelector(\"[data-testid=control-button-playpause]\");var m=document.querySelector(\"video,audio\");if(m && !m.paused){if(m.__fade)clearInterval(m.__fade);var s=m.volume,i=0;m.__fade=setInterval(function(){i++;m.volume=Math.max(0,s*(1-i/10));if(i>=10){clearInterval(m.__fade);m.__fade=0;if(b){b.click()}m.volume=1}},15);return \"1\"}return \"0\"})()"
                      else
                        tell (tab ti of window wi) to set didit to execute javascript "(function(){var m=document.querySelector(\"video,audio\");if(m && !m.paused){if(m.__fade)clearInterval(m.__fade);var s=m.volume,i=0;m.__fade=setInterval(function(){i++;m.volume=Math.max(0,s*(1-i/10));if(i>=10){clearInterval(m.__fade);m.__fade=0;m.pause();m.volume=1}},15);return \"1\"}return \"0\"})()"
                      end if
                    end timeout
                  on error
                    set didit to "0"
                  end try
                  if didit is "1" then set out to out & ((item ti of idl) as text) & TS & u & linefeed
                end if
              end if
            end repeat
          end repeat
        end tell
      end if
    end timeout
  on error
  end try
end using terms from
return out
end run
OSA
)
  while IFS="$TAB" read -r id url; do
    [ -z "$id" ] && continue
    printf '%s\t%s\t%s\n' "$app" "$id" "$url" >> "$STATE_FILE"
  done <<< "$out"
}

# resume_tab <app> <tabId> <url>
# Find the tab with <tabId> (matched by id, so track changes / reorders are
# fine) and fade it back in + play. No-op if the tab is gone or suspended.
resume_tab() {
  osascript - "$1" "$2" "$3" <<'OSA' >/dev/null 2>&1
on run argv
set appName to item 1 of argv
set theId to item 2 of argv
set u to item 3 of argv
using terms from application "Google Chrome"
  try
    with timeout of 4 seconds
      if application appName is running then
        tell application appName
          repeat with wi from 1 to count of windows
            set idl to id of tabs of window wi
            repeat with ti from 1 to count of idl
              if ((item ti of idl) as text) is theId then
                set t to tab ti of window wi
                -- guard against tab-id reuse after a browser restart: the host
                -- must still match (track changes keep the host, so they're fine)
                if (my hostOf(URL of t)) is (my hostOf(u)) then
                if u contains "open.spotify.com" then
                  tell t to execute javascript "(function(){var b=document.querySelector(\"[data-testid=control-button-playpause]\");var m=document.querySelector(\"video,audio\");if(m){if(m.__fade)clearInterval(m.__fade);m.volume=0;if(m.paused && b){b.click()}var i=0;m.__fade=setInterval(function(){i++;m.volume=Math.min(1,i/10);if(i>=10){clearInterval(m.__fade);m.__fade=0;m.volume=1}},15)}})()"
                else
                  tell t to execute javascript "(function(){var m=document.querySelector(\"video,audio\");if(m){if(m.__fade)clearInterval(m.__fade);m.volume=0;if(m.paused){m.play()}var i=0;m.__fade=setInterval(function(){i++;m.volume=Math.min(1,i/10);if(i>=10){clearInterval(m.__fade);m.__fade=0;m.volume=1}},15)}})()"
                end if
                end if
              end if
            end repeat
          end repeat
        end tell
      end if
    end timeout
  on error
  end try
end using terms from
return ""
end run

on hostOf(theUrl)
  try
    set d to (offset of "://" in theUrl)
    if d is 0 then return theUrl
    set afterScheme to text (d + 3) thru -1 of theUrl
    set s to (offset of "/" in afterScheme)
    if s is 0 then return afterScheme
    return text 1 thru (s - 1) of afterScheme
  on error
    return theUrl
  end try
end hostOf
OSA
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

# Wait for all background jobs but never longer than they should take. Each
# worker self-limits to <=4s, so a plain `wait` is bounded; this is just a named
# wrapper for readability.
drain() { wait; }

do_pause() {
  local before after added app
  before=$(wc -l < "$STATE_FILE" 2>/dev/null || echo 0)
  # one fused scan per browser, both in parallel: detect+fade+pause in a single
  # osascript each, so the playing tab silences in ~one round trip (~150-200ms).
  for app in "${BROWSERS[@]}"; do
    fused_scan "$app" &
  done
  drain
  after=$(wc -l < "$STATE_FILE" 2>/dev/null || echo 0)
  added=$((after - before))
  if [ "$added" -gt 0 ]; then
    log "paused $added tab(s) (outstanding: $after) -> $STATE_FILE"
  else
    log "nothing playing"
  fi
}

do_resume() {
  [ -s "$STATE_FILE" ] || { log "resume: nothing recorded"; return; }
  local app id url n=0 count=0
  while IFS="$TAB" read -r app id url; do
    [ -z "$app" ] && continue
    resume_tab "$app" "$id" "$url" &
    count=$((count + 1)); n=$((n + 1))
    if [ "$n" -ge "$MAX_PARALLEL" ]; then drain; n=0; fi
  done < "$STATE_FILE"
  drain
  : > "$STATE_FILE"
  log "resumed $count tab(s); state cleared"
}

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

# Kill any older instances of this exact script (e.g. one wedged across a
# launchd restart) so exactly one daemon runs.
kill_orphans() {
  local self="$1" p
  for p in $(pgrep -f "$self" 2>/dev/null); do
    [ "$p" = "$$" ] || kill "$p" 2>/dev/null
  done
  sleep 0.5
  for p in $(pgrep -f "$self" 2>/dev/null); do
    [ "$p" = "$$" ] || kill -9 "$p" 2>/dev/null
  done
}

# Log actionable diagnostics about each browser's automation readiness.
self_check() {
  if ! osascript -e 'using terms from application "Google Chrome"' -e 'return 1' -e 'end using terms from' >/dev/null 2>&1; then
    log "WARNING: terminology donor 'Google Chrome' unavailable — execute javascript will fail for ALL browsers. Install Chrome (or change the donor in this script)."
  fi
  local app res
  for app in "${BROWSERS[@]}"; do
    res=$(osascript - "$app" <<'OSA' 2>&1
on run argv
set appName to item 1 of argv
try
  with timeout of 3 seconds
    if not (application appName is running) then return "not-running"
  end timeout
on error
  return "not-installed"
end try
using terms from application "Google Chrome"
  try
    with timeout of 3 seconds
      tell application appName
        if (count of windows) is 0 then return "no-windows"
        tell (active tab of window 1) to execute javascript "1"
      end tell
    end timeout
    return "ok"
  on error errMsg number errNum
    return "ERR " & errNum & ": " & errMsg
  end try
end using terms from
end run
OSA
)
    case "$res" in
      ok)            log "self-check: $app — ready" ;;
      not-running)   log "self-check: $app — not running (handled if launched later)" ;;
      not-installed) log "self-check: $app — not installed (skipped)" ;;
      no-windows)    log "self-check: $app — running, no windows" ;;
      *-1743*)       log "self-check: $app — NEEDS Automation permission: System Settings ▸ Privacy & Security ▸ Automation ▸ allow control of $app" ;;
      *turned\ off*|*-2700*) log "self-check: $app — enable: $app ▸ View ▸ Developer ▸ Allow JavaScript from Apple Events" ;;
      *)             log "self-check: $app — $res" ;;
    esac
  done
}

main() {
  # 1) singleton
  kill_orphans "${BASH_SOURCE[0]}"
  # 2) ignore a stale press left from before this start (don't act on boot)
  last_handled="$(cat "$PRESS_FILE" 2>/dev/null)"
  # 3) discard stale pause state (can't reliably resume across a daemon restart)
  : > "$STATE_FILE" 2>/dev/null
  # 4) trim an oversized log in place (keeps launchd's open fd valid)
  if [ -f "$LOG_FILE" ]; then
    local sz; sz=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    [ "$sz" -gt "$LOG_MAX_BYTES" ] && : > "$LOG_FILE"
  fi

  self_check
  log "started; watching $PRESS_FILE (poll=${POLL_S}s, max_parallel=$MAX_PARALLEL, browsers: ${BROWSERS[*]})"

  while true; do
    if [ -f "$PRESS_FILE" ]; then
      line=$(cat "$PRESS_FILE" 2>/dev/null)
      if [ -n "$line" ] && [ "$line" != "$last_handled" ]; then
        last_handled="$line"
        case "${line%% *}" in
          pause)  do_pause ;;
          resume) do_resume ;;
          *)      log "unknown action: $line" ;;
        esac
      fi
    fi
    sleep "$POLL_S"
  done
}

main
