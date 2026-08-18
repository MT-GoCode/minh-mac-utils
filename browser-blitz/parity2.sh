#!/bin/bash
# parity2.sh — the surface parity.sh skipped: real interaction verbs, emulation,
# tabs/windows, frames, network extras. usage: parity2.sh <port>
#
# Serves its fixture over real HTTP: Chrome blocks top-level data: navigation, and
# localStorage/cookies need a real origin, so a data: URL fixture fails for reasons that
# have nothing to do with the bridge.
export PATH=/opt/homebrew/bin:$PATH
PORT="${1:?usage: parity2.sh <port>}"
AB="agent-browser --cdp $PORT"
FIXTURE_PORT=9977
PASS=0; FAIL=0; declare -a FAILED

cat > /tmp/parity-fixture.js <<'JS'
const http = require('http');
const HTML = `<!doctype html><html><body>
<input id=txt><input id=chk type=checkbox>
<select id=sel><option value=a>A</option><option value=b>B</option></select>
<button id=btn onclick="document.title='clicked'">Go</button>
<div id=hov onmouseover="this.dataset.h=1">hover me</div>
<a id=lnk href="https://example.com">link</a>
<iframe id=fr srcdoc="<p id=inner>frame content</p>"></iframe>
</body></html>`;
http.createServer((_, res) => { res.writeHead(200, {'Content-Type':'text/html'}); res.end(HTML); })
    .listen(9977, '127.0.0.1');
JS
node /tmp/parity-fixture.js & FIXPID=$!
sleep 1
trap 'kill $FIXPID 2>/dev/null' EXIT

t() {
  local name=$1 want=$2; shift 2
  local out rc
  out=$(timeout 30 "$@" 2>&1 | head -4); rc=$?
  if [ -n "$want" ]; then
    echo "$out" | grep -qi -- "$want" && { printf '  \033[32mPASS\033[0m  %s\n' "$name"; PASS=$((PASS+1)); return; }
  elif [ "$rc" = 0 ] && ! echo "$out" | grep -q '✗'; then
    printf '  \033[32mPASS\033[0m  %s\n' "$name"; PASS=$((PASS+1)); return
  fi
  printf '  \033[31mFAIL\033[0m  %-20s %s\n' "$name" "$(echo "$out" | head -1 | cut -c1-70)"
  FAIL=$((FAIL+1)); FAILED+=("$name")
}

$AB open "http://127.0.0.1:$FIXTURE_PORT/" >/dev/null 2>&1; sleep 2

echo "== interaction"
t "fill"            ""          $AB fill "#txt" "hello world"
t "fill readback"   "hello"     $AB get value "#txt"
t "type (append)"   ""          $AB type "#txt" "!!"
t "click"           ""          $AB click "#btn"
t "click effect"    "clicked"   $AB get title
t "check"           ""          $AB check "#chk"
t "is checked"      ""          $AB is checked "#chk"
t "uncheck"         ""          $AB uncheck "#chk"
t "select option"   ""          $AB select "#sel" "b"
t "select readback" "b"         $AB get value "#sel"
t "hover"           ""          $AB hover "#hov"
t "focus"           ""          $AB focus "#txt"
t "press"           ""          $AB press Tab
t "dblclick"        ""          $AB dblclick "#btn"
t "scrollintoview"  ""          $AB scrollintoview "#lnk"

echo "== refs"
REF=$($AB snapshot -i -c 2>/dev/null | grep -o 'ref=e[0-9]*' | head -1 | cut -d= -f2)
t "click by @ref"   ""          $AB click "@${REF:-e1}"

echo "== frames"
t "frame switch"    ""          $AB frame "#fr"
$AB frame main >/dev/null 2>&1

echo "== emulation"
t "set viewport"    ""          $AB set viewport 1280 800
t "set media dark"  ""          $AB set media dark
t "set geo"         ""          $AB set geo 37.7749 -122.4194
t "set offline on"  ""          $AB set offline on
$AB set offline off >/dev/null 2>&1

echo "== storage / cookies (real origin)"
t "storage set"     ""          $AB storage local set paritykey parityval
t "storage get"     "parityval" $AB storage local paritykey
t "cookies set"     ""          $AB cookies set paritycookie 1

echo "== network extras"
t "har start"       ""          $AB network har start
t "har stop"        ""          $AB network har stop /tmp/parity.har
t "unroute"         ""          $AB network unroute

echo "== tabs / capture / vitals"
t "tab new"         ""          $AB tab new "http://127.0.0.1:$FIXTURE_PORT/"
t "tab list"        ""          $AB tab
t "pushstate"       ""          $AB pushstate "/parity"
t "pdf"             ""          $AB pdf /tmp/parity.pdf
t "screenshot full" ""          $AB screenshot --full /tmp/parity-full.png
t "vitals"          ""          $AB vitals

echo
echo "PASS=$PASS FAIL=$FAIL"
[ ${#FAILED[@]} -gt 0 ] && printf 'failed: %s\n' "${FAILED[*]}"
exit 0
