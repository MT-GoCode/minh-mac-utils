#!/bin/bash
# test.sh — behavioural checks for pacemaker. Run on each machine.
#
# These assert what running it actually does. Three bugs got through unit-style checking
# and only showed up live: argv quoting silently destroyed (`sh -c 'sleep 60'` became
# `sh -c sleep`), output consumed on polls that did not emit, and a job dying with the
# Monitor because a new session alone does not survive a process-tree kill.
set -uo pipefail
PM="${1:-$(cd "$(dirname "$0")" && pwd)/pacemaker}"
pass=0; fail=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
no() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

[ -x "$PM" ] || { echo "not executable: $PM" >&2; exit 2; }
echo "testing $PM"

H=~/.pacemaker
clean() { rm -rf "$H/$1" "$H/$1"-*; }
pid_of() { python3 -c "import json;print(json.load(open('$H/$1/meta'))['pid'])" 2>/dev/null; }

# ---------------------------------------------------------------- pass-through
clean t_quick
out="$("$PM" --slug t_quick --every 5 -- sh -c 'echo hello; echo oops >&2; exit 3' 2>&1)"
case "$out" in
  *"completed in"*"with exit code 3"*) ok "a short job reports its real exit code" ;;
  *) no "completion wording wrong: $out" ;;
esac
grep -q '^hello$'  <<<"$out" && ok "stdout is passed through unlabelled" || no "no bare stdout: $out"
grep -q '^stderr:$' <<<"$out" && grep -q '^oops$' <<<"$out" \
  && ok "stderr is passed through, labelled" || no "stderr missing or unlabelled"
grep -q Heartbeat <<<"$out" && no "a sub-60s job must stay silent" || ok "no heartbeat under 60s"

# ---------------------------------------------------------------- truncation
clean t_trunc
out="$("$PM" --slug t_trunc -- sh -c 'for i in $(seq 1 70); do echo "line $i"; done' 2>&1)"
grep -q 'lines omitted' <<<"$out" && ok "a long burst is truncated" || no "no truncation at 70 lines"
grep -q "full log at .*t_trunc/stdout" <<<"$out" \
  && ok "truncation says where the full log is" || no "no log path in the omission marker"
grep -q '^line 1$'  <<<"$out" && ok "truncation keeps the head" || no "head dropped"
grep -q '^line 70$' <<<"$out" && ok "truncation keeps the tail" || no "tail dropped"
clean t_trunc

# ---------------------------------------------------------------- quoting
clean t_quote
out="$("$PM" --slug t_quote --every 5 -- sh -c 'printf "%s\n" "a b c"' 2>&1)"
grep -q '^a b c$' <<<"$out" && ok "argv quoting survives (sh -c with spaces)" \
  || no "quoting destroyed: $out"

# ---------------------------------------------------------------- detachment
clean t_surv
"$PM" --slug t_surv --every 300 -- sh -c 'sleep 25; echo LIVED > /tmp/pm_lived' >/dev/null 2>&1 &
pm=$!; sleep 3
job="$(pid_of t_surv)"
ppid="$(ps -o ppid= -p "$job" 2>/dev/null | tr -d ' ')"
[ "$ppid" = 1 ] && ok "job is reparented to init (ppid 1), not a child of pacemaker" \
                || no "job ppid is $ppid — a tree kill would reach it"
kill -9 "$pm" 2>/dev/null; sleep 2
if kill -0 "$job" 2>/dev/null; then ok "job survives pacemaker being killed"; else no "job died with pacemaker"; fi
rm -f /tmp/pm_lived

# ---------------------------------------------------------------- attach
"$PM" --slug t_surv --attach --every 300 >/tmp/pm_att.out 2>&1 &
a=$!; sleep 3
for c in $(pgrep -P $a 2>/dev/null); do kill "$c" 2>/dev/null; done; kill $a 2>/dev/null; wait $a 2>/dev/null
grep -q 'Re-attached to t_surv' /tmp/pm_att.out && ok "attach resumes a live run by slug alone" \
  || no "attach failed: $(head -1 /tmp/pm_att.out)"
grep -q 'running for' /tmp/pm_att.out && ok "attach reports elapsed from the original start" \
  || no "no elapsed on attach"
rm -f /tmp/pm_att.out
kill -9 -"$(pid_of t_surv)" 2>/dev/null
clean t_surv

out="$("$PM" --slug t_nosuch --attach 2>&1)"
grep -q 'no run named' <<<"$out" && ok "attach to a missing run says so" || no "bad missing-run message: $out"

# ---------------------------------------------------------------- timeout
clean t_tmo
start=$(date +%s)
out="$("$PM" --slug t_tmo --every 300 --timeout 3 -- sh -c 'sleep 120' 2>&1)"
took=$(( $(date +%s) - start ))
grep -q 'hit --timeout' <<<"$out" && ok "timeout fires and says so" || no "no timeout message: $out"
[ "$took" -lt 30 ] && ok "timeout returns promptly (${took}s)" || no "timeout took ${took}s"
sleep 1
pgrep -f 'sleep 120' >/dev/null && no "the real command survived --timeout" \
                                || ok "--timeout killed the command, not just the wrapper"
[ "$(cat "$H/t_tmo/exit" 2>/dev/null)" = 124 ] && ok "timeout records exit 124" \
                                               || no "no 124 in exit file"

# ---------------------------------------------------------------- died with no exit code
clean t_died
"$PM" --slug t_died --every 300 -- sh -c 'sleep 120' >/tmp/pm_died.out 2>&1 &
pm=$!; sleep 3
kill -9 -"$(pid_of t_died)" 2>/dev/null
sleep 3; kill "$pm" 2>/dev/null
grep -q 'died after' /tmp/pm_died.out && ok "a job killed from outside is reported as died" \
                                      || no "no died message: $(head -2 /tmp/pm_died.out)"
rm -f /tmp/pm_died.out

# ---------------------------------------------------------------- collision
clean t_dup
"$PM" --slug t_dup --every 300 -- sh -c 'sleep 30' >/dev/null 2>&1 &
pm=$!; sleep 2
out="$("$PM" --slug t_dup --every 300 -- sh -c 'echo second' 2>&1)"
grep -q 'already running' <<<"$out" && ok "a second run on a live slug is refused" \
                                    || no "collision not caught: $out"
kill -9 -"$(pid_of t_dup)" 2>/dev/null; kill "$pm" 2>/dev/null; clean t_dup

# ---------------------------------------------------------------- argument validation
"$PM" --slug x --every 301 >/dev/null 2>&1;  [ $? -ne 0 ] && ok "--every above 300 rejected" || no "--every 301 accepted"
"$PM" --slug x --timeout 1801 >/dev/null 2>&1; [ $? -ne 0 ] && ok "--timeout above 1800 rejected" || no "--timeout 1801 accepted"
"$PM" --every 60 >/dev/null 2>&1;            [ $? -ne 0 ] && ok "--slug is required" || no "ran without --slug"
"$PM" --slug a/b >/dev/null 2>&1;            [ $? -ne 0 ] && ok "a path-like slug is rejected" || no "slug a/b accepted"

# ---------------------------------------------------------------- prune safety
clean t_live
"$PM" --slug t_live --every 300 -- sh -c 'sleep 30' >/dev/null 2>&1 &
pm=$!; sleep 2
touch -d '2020-01-01' "$H/t_live" 2>/dev/null || touch -t 202001010000 "$H/t_live"
clean t_other
"$PM" --slug t_other --every 5 -- sh -c 'true' >/dev/null 2>&1      # triggers prune()
[ -d "$H/t_live" ] && ok "prune leaves a live run alone despite an ancient mtime" \
                   || no "PRUNE DELETED A LIVE RUN"
kill -9 -"$(pid_of t_live)" 2>/dev/null; kill "$pm" 2>/dev/null; clean t_live; clean t_other

# ---------------------------------------------------------------- reminder shape
out="$(timeout 5 "$PM" --slug t_rem --every 2 2>&1 | head -2)"
grep -q 'Reminder to check on t_rem' <<<"$out" && ok "the bare reminder shape pings" \
                                               || no "no reminder output: $out"
[ -d "$H/t_rem" ] && no "the reminder shape should keep no files" || ok "the reminder keeps no files"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32m%d/%d passed\033[0m\n' "$pass" "$pass"
else printf '\033[31m%d of %d FAILED\033[0m\n' "$fail" "$((pass+fail))"; exit 1; fi
