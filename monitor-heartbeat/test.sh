#!/bin/bash
# test.sh — behavioural checks for monitor-heartbeat. Run after install, on each machine.
#
# These assert that time actually advances. `--help` passing proves nothing: the first
# version of this tool ran clean on macOS and reported quiet=0 forever, because `stat` is
# GNU in a login shell and BSD over plain ssh on the same Mac, and the wrong dialect returns
# a filesystem report that was then silently read as "no time has passed".
#
#   ./test.sh [path-to-monitor-heartbeat]
set -uo pipefail
MH="${1:-$HOME/.local/bin/monitor-heartbeat}"
pass=0; fail=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
no() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

[ -x "$MH" ] || { echo "not executable: $MH" >&2; exit 2; }
echo "testing $MH   (stat dialect here: $(stat -c %Y / >/dev/null 2>&1 && echo GNU || echo BSD))"

# Take one heartbeat. Never pipe this tool to `head`: it does not exit, so head would take
# its line and leave the writer blocked until its next write — the trap the Monitor docs
# describe for `tail -f | grep -m 1`. Background it, read, kill it.
tick() {
  local o p
  o="$(mktemp)"
  "$MH" "$@" > "$o" 2>&1 &
  p=$!
  sleep 1
  kill "$p" 2>/dev/null
  wait "$p" 2>/dev/null
  head -1 "$o"
  rm -f "$o"
}

log="$(mktemp)"
echo start > "$log"
sleep 3   # let real time pass, so "quiet 0s" can only mean a broken clock source

line="$(tick "$log" --every 3600)"
case "$line" in
  *"quiet 0s"*) no "quiet does not advance — wrong stat dialect on this machine: $line" ;;
  *quiet*)      ok "quiet advances: $line" ;;
  *)            no "unexpected output: $line" ;;
esac
case "$line" in
  *"since start"*) ok "reports elapsed" ;;
  *)               no "no elapsed in: $line" ;;
esac

line="$(tick "$log" --every 3600 --quiet-after 2)"
case "$line" in
  *hung*) ok "hung? fires past --quiet-after" ;;
  *)      no "hung? did not fire when it should: $line" ;;
esac

line="$(tick "$log" --every 3600 --quiet-after 9999)"
case "$line" in
  *hung*) no "hung? fired below the threshold: $line" ;;
  *)      ok "no false hung? below the threshold" ;;
esac

# Elapsed comes from the log's birth time, so a watcher armed later must agree with one
# armed earlier. This is what makes re-arming a Monitor honest.
a="$(tick "$log" --every 3600)"
sleep 2
b="$(tick "$log" --every 3600)"
ea="$(printf '%s' "$a" | sed -n 's/heartbeat \([0-9hms]*\) since.*/\1/p')"
eb="$(printf '%s' "$b" | sed -n 's/heartbeat \([0-9hms]*\) since.*/\1/p')"
if [ -n "$ea" ] && [ "$ea" != "$eb" ]; then
  ok "elapsed continues across a fresh watcher ($ea -> $eb)"
else
  no "elapsed did not advance across watchers ($ea -> $eb) — birth time unavailable?"
fi

line="$(tick "/tmp/definitely-not-here-$$" --every 3600)"
case "$line" in
  *"no log at"*) ok "missing log reported, not crashed" ;;
  *)             no "missing log handled wrong: $line" ;;
esac

"$MH" >/dev/null 2>&1
[ $? -eq 2 ] && ok "no args exits 2" || no "no args should exit 2"

"$MH" "$log" --every abc >/dev/null 2>&1
[ $? -eq 2 ] && ok "non-numeric --every rejected" || no "bad --every was accepted"

rm -f "$log"
echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32m%d/%d passed\033[0m\n' "$pass" "$pass"
else
  printf '\033[31m%d of %d FAILED\033[0m\n' "$fail" "$((pass+fail))"
  exit 1
fi
