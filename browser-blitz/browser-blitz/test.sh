#!/bin/bash
# browser-blitz interaction suite. Run it ON the Mac: ./test.sh
#
# Drives the real Chrome, so every session it makes is prefixed `bbt` and torn down on exit —
# including on failure. It never touches a slug it did not create, and never runs kill-all,
# because other agents and the user share this machine.

set -u
PASS=0; FAIL=0

# Sweeps `bb list` rather than a remembered array: `new` runs inside $( ), which is a subshell,
# so anything it appended to a variable was thrown away and eight sessions leaked out of the
# first two runs. The `bbt` prefix belongs to this suite alone, so taking all of them is safe.
cleanup() { for s in $(bb list 2>/dev/null | grep -oE '^bbt[a-z][0-9]+'); do bb delete-session "$s" >/dev/null 2>&1; done; }
trap cleanup EXIT

sec()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; }
# is <name> <expected-substring> <actual>
# The empty needle is rejected outright: `case "$x" in *""*)` matches ANY string, so
# `is <name> "" "$out"` used to pass unconditionally. Four checks were decorative that way,
# including both of the ones that supposedly proved the poisoning claim. Use `empty` for
# "I expect no output".
is()   { [ -n "$2" ] || { bad "$1" "a non-empty needle (use \`empty\`)" "<empty needle>"; return; }
         case "$3" in *"$2"*) ok "$1";; *) bad "$1" "$2" "$3";; esac; }
isnt() { [ -n "$2" ] || { bad "$1" "a non-empty needle" "<empty needle>"; return; }
         case "$3" in *"$2"*) bad "$1" "NOT $2" "$3";; *) ok "$1";; esac; }
empty(){ [ -z "$2" ] && ok "$1" || bad "$1" "<no output>" "$2"; }

# Polls instead of sleeping. A flat `sleep 7` is too long warm and too short on a cold Chrome,
# where ensureProfileReady alone allows 25s — and a creation that failed used to sail on
# silently and take every later check in its section down with it.
wait_live() { for _ in $(seq 30); do case "$(row "$1")" in *LIVE*) return 0;; esac; sleep 1; done; return 1; }
new()  { local s="bbt$1$RANDOM"; bb new-session "$s" >/dev/null 2>&1
         wait_live "$s" || bad "SETUP: $s never came up LIVE" "LIVE" "$(row "$s")"; echo "$s"; }
drive(){ timeout 45 playwright-cli -s="$1" run-code "$2" 2>&1 | sed -n 2p; }
row()  { bb list 2>/dev/null | awk -v s="$1" '$1==s'; }

# ---------------------------------------------------------------- A. lifecycle
sec "A. lifecycle"
A="bbta$RANDOM"
A_OUT=$(bb new-session "$A" 2>&1); wait_live "$A" || bad "SETUP: $A never came up LIVE" "LIVE" "$(row "$A")"
is  "new-session prints the CDP url"                     "http://127.0.0.1:9342/$A" "$A_OUT"
isnt "new-session does not print internals"              "groupId"                  "$A_OUT"
is  "list shows it LIVE"                                 "LIVE"                     "$(row "$A")"
is  "DRIVER says connected while the daemon holds it"    "connected"                "$(row "$A")"
isnt "list has no BOUND column"                          "BOUND"                    "$(bb list | head -1)"
bb delete-session "$A" >/dev/null 2>&1
empty "delete then list immediately is clean"                                       "$(row "$A")"
isnt "no UNTRACKED flash after delete"                   "UNTRACKED"                "$(row "$A")"

# ---------------------------------------------------------------- B. driving
sec "B. driving"
B=$(new b)
is "navigate and read the title" "Example Domain" "$(drive "$B" 'async page => { await page.goto("https://example.com"); return page.title(); }')"
is "a new page opens inside the session" "2 pages" \
   "$(drive "$B" 'async page => { const p = await page.context().newPage(); await p.goto("https://example.com/#two"); return page.context().pages().length + " pages"; }')"
sleep 3
is "both tabs are owned by the session" "2" "$(bb list-tabs | awk -v s="$B" '$2==s' | wc -l | tr -d ' ')"
is "snapshot lists the open tabs" "Open tabs" "$(timeout 45 playwright-cli -s="$B" snapshot 2>&1 | head -2)"
is "chained actions run in one call" "chained" \
   "$(drive "$B" 'async page => { await page.goto("https://example.com"); await page.waitForLoadState("domcontentloaded"); return "chained"; }')"

# ---------------------------------------------------------------- C. the fence
sec "C. the fence"
C=$(new c)
drive "$C" 'async page => { await page.goto("https://example.com/#inC"); return 1; }' >/dev/null
isnt "session C cannot see session B's pages" "#two" "$(drive "$C" 'async page => page.context().pages().map(p => p.url())')"
isnt "session B cannot see session C's pages" "#inC" "$(drive "$B" 'async page => page.context().pages().map(p => p.url())')"
empty "no tab is claimed by two sessions" \
      "$(bb list-tabs | awk 'NR>1{print $1}' | sort | uniq -d)"

# ---------------------------------------------------------------- D. tab verbs
sec "D. tab verbs"
is "bring-to-front returns the raised tab" "TABID" "$(bb "$C" bring-to-front 2>&1 | head -1)"
# Releasing the LAST tab is refused on purpose, so give C a second one first.
drive "$C" 'async page => { const p = await page.context().newPage(); await p.goto("about:blank"); return 1; }' >/dev/null
sleep 3
is "releasing the last tab is refused, by name" "every tab in session" \
   "$(bb "$C" release-tab $(bb list-tabs | awk -v c="$C" '$2==c {print $1}' | tr '\n' ' ') 2>&1 | tail -1)"
LOOSE=$(bb list-tabs | awk -v c="$C" '$2==c {print $1; exit}')
is "release-tab takes a tab out of the session" "true" "$(bb "$C" release-tab "$LOOSE" 2>&1 | tail -1)"
sleep 2
is "grab-tab pulls it back in" "true" "$(bb "$C" grab-tab "$LOOSE" 2>&1 | tail -1)"

# ---------------------------------------------------------------- E. errors read clearly
sec "E. errors"
is "delete of an absent session is idempotent"  "nothing to close" "$(bb delete-session bbt-does-not-exist 2>&1)"
is "resume of an absent session names it"       "no session"       "$(bb resume bbt-does-not-exist 2>&1)"
is "illegal slug is rejected with the rule"     "invalid slug"     "$(bb new-session 'has space/slash' 2>&1)"
is "a command name cannot become a slug"        "command name"     "$(bb new-session list 2>&1)"
is "duplicate new-session points at resume"     "already exists"   "$(bb new-session "$C" 2>&1)"
is "a bad verb names the verb"                  "'teleport' is not one of its verbs" "$(bb "$C" teleport 2>&1)"
is "...and does not guess which half is wrong"  "is not a command"                   "$(bb "$C" teleport 2>&1)"
is "non-numeric tab id is rejected"             "whole-number"     "$(bb "$C" grab-tab abc 2>&1)"
is "an unread flag is an error, not ignored"    "takes --json"     "$(bb list --bogus 2>&1)"

# ---------------------------------------------------------------- F. resume
sec "F. resume"
F=$(new f)
drive "$F" 'async page => { await page.close(); return 1; }' >/dev/null 2>&1
sleep 3
is "closing the last tab marks it CLOSED" "CLOSED" "$(row "$F")"
bb resume "$F" >/dev/null 2>&1; sleep 6
is "resume brings it back LIVE"           "LIVE"          "$(row "$F")"
is "and it drives again"                  "about:blank"   "$(drive "$F" 'async page => page.url()')"

# ---------------------------------------------------------------- G. a detached slug is poisoned
sec "G. poisoning (documented behaviour, not a bug to fix)"
G=$(new g)
is "healthy before detach"    "about:blank" "$(drive "$G" 'async page => page.url()')"
is "DRIVER connected before"  "connected"   "$(row "$G")"
playwright-cli -s="$G" detach >/dev/null 2>&1; sleep 5
isnt "DRIVER drops when the daemon lets go" "connected" "$(row "$G")"
empty "after detach it hangs, returning nothing" "$(drive "$G" 'async page => page.url()')"
bb resume "$G" >/dev/null 2>&1; sleep 5
empty "bb resume does NOT revive a poisoned slug" "$(drive "$G" 'async page => page.url()')"
bb delete-session "$G" >/dev/null 2>&1; sleep 3
bb new-session "$G" >/dev/null 2>&1; sleep 7
is "delete + recreate is the recovery" "about:blank" "$(drive "$G" 'async page => page.url()')"

# ----------------------------------------------------------------
sec "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
