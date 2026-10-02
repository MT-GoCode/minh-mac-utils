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
  # kill the child sleep too, or every tick() leaks one for --every seconds
  for c in $(pgrep -P "$p" 2>/dev/null); do kill "$c" 2>/dev/null; done
  kill "$p" 2>/dev/null
  wait "$p" 2>/dev/null
  cat "$o"
  rm -f "$o"
}

log="$(mktemp)"
echo start > "$log"
sleep 3   # let real time pass, so "quiet 0s" can only mean a broken clock source

line="$(tick "$log" --every 180 | head -1)"
case "$line" in
  *"quiet 0s"*) no "quiet does not advance — wrong stat dialect on this machine: $line" ;;
  *quiet*)      ok "quiet advances: $line" ;;
  *)            no "unexpected output: $line" ;;
esac
case "$line" in
  *"since start"*) ok "reports elapsed" ;;
  *)               no "no elapsed in: $line" ;;
esac

line="$(tick "$log" --every 180 --quiet-after 2 | head -1)"
case "$line" in
  *hung*) ok "hung? fires past --quiet-after" ;;
  *)      no "hung? did not fire when it should: $line" ;;
esac

line="$(tick "$log" --every 180 --quiet-after 9999 | head -1)"
case "$line" in
  *hung*) no "hung? fired below the threshold: $line" ;;
  *)      ok "no false hung? below the threshold" ;;
esac

# Elapsed comes from the log's birth time, so a watcher armed later must agree with one
# armed earlier. This is what makes re-arming a Monitor honest.
a="$(tick "$log" --every 180 | head -1)"
sleep 2
b="$(tick "$log" --every 180 | head -1)"
# the line is: heartbeat <name> | <dur> since start | ...
ea="$(printf '%s' "$a" | sed -n 's/.*| \([0-9hms]*\) since start.*/\1/p')"
eb="$(printf '%s' "$b" | sed -n 's/.*| \([0-9hms]*\) since start.*/\1/p')"
if [ -n "$ea" ] && [ "$ea" != "$eb" ]; then
  ok "elapsed continues across a fresh watcher ($ea -> $eb)"
else
  no "elapsed did not advance across watchers ($ea -> $eb) — birth time unavailable?"
fi

line="$(tick "/tmp/definitely-not-here-$$" --every 180 | head -1)"
case "$line" in
  *"no log at"*) ok "missing log reported, not crashed" ;;
  *)             no "missing log handled wrong: $line" ;;
esac

"$MH" >/dev/null 2>&1
[ $? -eq 2 ] && ok "no args exits 2" || no "no args should exit 2"

"$MH" "$log" --every abc >/dev/null 2>&1
[ $? -eq 2 ] && ok "non-numeric --every rejected" || no "bad --every was accepted"

# --- regressions from the adversarial review -------------------------------------
line="$(tick "$log" --every 180 | head -1)"
case "$line" in *arming*) ok "a fresh watcher arms rather than claiming a delta" ;; *) no "no arming marker in $line" ;; esac
case "$line" in heartbeat\ *"$(basename "$log")"*) ok "line names the log" ;; *) no "line does not name the log: $line" ;; esac

fut="$(mktemp)"; echo x > "$fut"
touch -d '+2 hours' "$fut" 2>/dev/null || touch -A 020000 "$fut"
line="$(tick "$fut" --every 180 | head -1)"
case "$line" in *FUTURE*) ok "future mtime reported, not clamped to quiet 0" ;; *) no "clock skew hidden: $line" ;; esac
rm -f "$fut"

line="$(tick "/tmp/nope-$$" --every 180 --quiet-after 0 | head -1)"
case "$line" in *"wrong path"*) ok "missing log escalates past --quiet-after" ;; *) no "missing log never escalates: $line" ;; esac

( sleep 0.1 ) & dead=$!; wait "$dead" 2>/dev/null
line="$(tick "$log" --every 180 --pid "$dead" | head -1)"
case "$line" in *"IS GONE"*) ok "--pid detects the job ended" ;; *) no "--pid missed a dead job: $line" ;; esac

"$MH" "$log" "$log" >/dev/null 2>&1
[ $? -eq 2 ] && ok "two logfiles rejected" || no "second positional silently won"

before=$(ps -eo ppid,args --no-headers 2>/dev/null | awk '$1==1 && /sleep 600/' | wc -l)
"$MH" "$log" --every 600 >/dev/null 2>&1 & k=$!
sleep 1; kill -TERM "$k" 2>/dev/null; wait "$k" 2>/dev/null; sleep 1
after=$(ps -eo ppid,args --no-headers 2>/dev/null | awk '$1==1 && /sleep 600/' | wc -l)
[ "$after" -le "$before" ] && ok "no orphan sleep after TERM" || no "orphaned $((after-before)) sleep(s)"

# The delta is per-process state, so it must be exercised inside ONE watcher: tick two
# separate times and each would re-read the whole file. A fresh watcher reports the tail as
# context ("arming"), and only subsequent ticks claim +N.
stream="$(mktemp)"; : > "$stream"
printf 'alpha\nbeta\n' > "$log"
"$MH" "$log" --every 1 > "$stream" 2>&1 &
s=$!
sleep 2; printf 'gamma\ndelta\n' >> "$log"; sleep 2
for c in $(pgrep -P "$s" 2>/dev/null); do kill "$c" 2>/dev/null; done
kill "$s" 2>/dev/null; wait "$s" 2>/dev/null

head -1 "$stream" | grep -q 'arming' \
  && ok "first tick says arming, does not claim a false delta" \
  || no "first tick: $(head -1 "$stream")"
grep -q '^| alpha' "$stream" && ok "arming shows existing output" || no "no existing output shown"
grep -q '+2 lines' "$stream" && ok "a later tick counts only what is new (+2)" || no "never reported +2: $(grep -c . "$stream") lines"
grep -q '^| gamma' "$stream" && ok "streams the new lines, marked" || no "gamma not streamed"
grep -q '+0 lines' "$stream" && ok "an idle tick reports +0" || no "never reported +0"
rm -f "$stream"

# A burst must keep its head, not just its tail: the phase markers and the first failure
# are at the front, and 50 trailing "ok" lines are the least informative slice.
burst="$(mktemp)"; : > "$burst"
"$MH" "$burst" --every 2 --tail 20 > "$burst.out" 2>&1 &
bp=$!
sleep 1
{ echo "FIRSTLINE"; for i in $(seq 1 90); do echo "filler $i"; done; echo "LASTLINE"; } >> "$burst"
sleep 3
for c in $(pgrep -P "$bp" 2>/dev/null); do kill "$c" 2>/dev/null; done; kill "$bp" 2>/dev/null; wait "$bp" 2>/dev/null
grep -q '^| FIRSTLINE' "$burst.out" && ok "a burst keeps its first lines" || no "head of the burst was dropped"
grep -q '^| LASTLINE'  "$burst.out" && ok "a burst keeps its last lines"  || no "tail of the burst was dropped"
grep -q 'lines omitted' "$burst.out" && ok "says how many it omitted" || no "no omission marker"
grep -q '^| ' "$burst.out" && ok "marker survives whitespace stripping" || no "no | marker"
rm -f "$burst" "$burst.out"

"$MH" "$log" --every 181 >/dev/null 2>&1
[ $? -eq 2 ] && ok "--every above 180 rejected" || no "--every 181 accepted"
"$MH" "$log" --every 180 --quiet-after 1 >/dev/null 2>&1 & q=$!; sleep 1
for c in $(pgrep -P "$q" 2>/dev/null); do kill "$c" 2>/dev/null; done; kill "$q" 2>/dev/null; wait "$q" 2>/dev/null
ok "--every 180 accepted"

rm -f "$log"
echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32m%d/%d passed\033[0m\n' "$pass" "$pass"
else
  printf '\033[31m%d of %d FAILED\033[0m\n' "$fail" "$((pass+fail))"
  exit 1
fi
