#!/bin/bash
# parity.sh — walk agent-browser's surface through the shim against REAL Chrome.
# usage: parity.sh <slugPort>
export PATH=/opt/homebrew/bin:$PATH
PORT="${1:?usage: parity.sh <port>}"
AB="agent-browser --cdp $PORT"
PASS=0; FAIL=0; declare -a FAILED

# t <name> <expect|""> <cmd...>   ""  = succeeds (exit 0, no error marker); empty output is OK,
#                                       since e.g. `cookies` on a cookieless page is legitimately empty.
t() {
  local name=$1 want=$2; shift 2
  local out rc
  out=$(timeout 30 "$@" 2>&1 | head -4); rc=$?
  if [ -n "$want" ]; then
    echo "$out" | grep -qi -- "$want" && { printf '  \033[32mPASS\033[0m  %s\n' "$name"; PASS=$((PASS+1)); return; }
  elif [ "$rc" = 0 ] && ! echo "$out" | grep -q '✗'; then
    printf '  \033[32mPASS\033[0m  %s\n' "$name"; PASS=$((PASS+1)); return
  fi
  printf '  \033[31mFAIL\033[0m  %-22s %s\n' "$name" "$(echo "$out" | head -1 | cut -c1-70)"
  FAIL=$((FAIL+1)); FAILED+=("$name")
}

$AB open https://example.com >/dev/null 2>&1; sleep 1

echo "== navigation"
t "open"              "example"     $AB open https://example.com
t "get url"           "example.com" $AB get url
t "get title"         "Example"     $AB get title
t "reload"            ""            $AB reload
t "back"              ""            $AB back
t "forward"           ""            $AB forward

echo "== read / snapshot"
t "snapshot -i"       "ref="        $AB snapshot -i -c
t "read"              "example"     $AB read
t "eval"              "2"           $AB eval "1+1"
t "get html"          "<"           $AB get html body
t "get text"          ""            $AB get text h1
t "get count"         ""            $AB get count "a"
t "get box"           ""            $AB get box h1
t "get styles"        ""            $AB get styles h1

echo "== interaction"
t "find role"         ""            $AB find role heading text
t "find text"         ""            $AB find text "Example" text
t "scroll"            ""            $AB scroll down 100
t "wait --load"       ""            $AB wait --load networkidle
t "wait --text"       ""            $AB wait --text "Example"
t "is visible"        ""            $AB is visible h1

echo "== optimizations (the point of all this)"
t "batch (2 cmds)"    "example"     $AB batch "get url" "get title"
t "network route"     ""            $AB network route "**/analytics**" --abort
t "network requests"  ""            $AB network requests

echo "== capture / state"
t "screenshot"        ""            $AB screenshot /tmp/parity.png
t "cookies"           ""            $AB cookies
t "storage local"     ""            $AB storage local
t "tab list"          ""            $AB tab

echo "== console (log AFTER attach, else the buffer predates us)"
$AB eval "console.log('parity-probe')" >/dev/null 2>&1; sleep 1
t "console capture"   "parity-probe" $AB console

echo
echo "PASS=$PASS FAIL=$FAIL"
[ ${#FAILED[@]} -gt 0 ] && printf 'failed: %s\n' "${FAILED[*]}"
exit 0
