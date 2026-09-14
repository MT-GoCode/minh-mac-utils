#!/bin/bash
# Post-install live verification (spec 2026-09-13-durability-design.md §Tests item 2).
# Run as the console user AFTER `sudo ./install.sh`. Automates what can be automated;
# prints the manual checklist at the end. Exits nonzero on any automated failure.
set -u
LABEL=com.minh.multistreamviewer.agent
BIN=/Applications/multistreamviewer.app/Contents/MacOS/multistreamviewer
UID_ME=$(id -u)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $1"; }
bad() { fail=$((fail+1)); echo "FAIL  $1"; }

wait_running() {  # <seconds>
  for _ in $(seq "$1"); do
    pgrep -fq "$BIN" && return 0
    sleep 1
  done
  return 1
}

echo "▸ agent loaded"
launchctl print "gui/$UID_ME/$LABEL" >/dev/null 2>&1 && ok "agent loaded in gui/$UID_ME" || bad "agent not loaded"

echo "▸ app running"
wait_running 5 && ok "app running" || bad "app not running"

echo "▸ status verb"
/usr/local/bin/multistreamviewer status && ok "status" || bad "status returned nonzero"

echo "▸ kill -9 → relaunched (ThrottleInterval 30, waiting up to 40s)"
pkill -9 -f "$BIN"
wait_running 40 && ok "relaunched after SIGKILL" || bad "not relaunched after SIGKILL"

echo "▸ plain kill (TERM, exit 1) → relaunched (waiting up to 40s)"
pkill -f "$BIN"
wait_running 40 && ok "relaunched after SIGTERM" || bad "not relaunched after SIGTERM"

echo
echo "$pass passed, $fail failed"
echo
echo "Manual checks remaining:"
echo "  · menu → Quit → stays quit; log out/in → back"
echo "  · close every window in the current desktop → ⌘⇥ shows ALL windows (fallback)"
echo "  · fast-user-switch to login window ≥30s, return → desktop tags intact"
echo "  · revoke Accessibility → menu shows ⚠ and 'multistreamviewer status' says tap DEAD; re-grant → heals within ~5s"
exit $((fail > 0))
