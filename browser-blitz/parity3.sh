#!/bin/bash
# parity3.sh — everything parity.sh and parity2.sh didn't cover.
# usage: parity3.sh <port>
export PATH=/opt/homebrew/bin:$PATH
PORT="${1:?usage: parity3.sh <port>}"
AB="agent-browser --cdp $PORT"
PASS=0; FAIL=0; SKIP=0; declare -a FAILED

cat > /tmp/p3-fixture.js <<'JS'
const http=require('http');
const HTML=`<!doctype html><html><body>
<input id=txt placeholder="type here" aria-label="Text field">
<input id=file type=file>
<img id=img alt="pic" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">
<button id=alertbtn onclick="alert('hi')">alert</button>
<button id=confirmbtn onclick="window.__c=confirm('ok?')">confirm</button>
<div id=src draggable=true>drag me</div><div id=dst>drop here</div>
<span data-testid=tid>testid target</span>
<div title="tooltip">title target</div>
<ul><li class=item>one</li><li class=item>two</li><li class=item>three</li></ul>
<button id=dis disabled>disabled</button>
<a id=slow href="#" onclick="setTimeout(()=>{location.hash='#done'},600);return false">slow</a>
<script>
document.getElementById('src').addEventListener('dragstart',e=>e.dataTransfer.setData('t','x'));
document.getElementById('dst').addEventListener('drop',e=>{e.preventDefault();e.target.textContent='dropped'});
document.getElementById('dst').addEventListener('dragover',e=>e.preventDefault());
</script></body></html>`;
http.createServer((_,res)=>{res.writeHead(200,{'Content-Type':'text/html'});res.end(HTML);}).listen(9979,'127.0.0.1');
JS
node /tmp/p3-fixture.js & FP=$!
sleep 1
trap 'kill $FP 2>/dev/null' EXIT
echo "parity3 fixture" > /tmp/p3-upload.txt

t() {
  local name=$1 want=$2; shift 2
  local out rc
  out=$(timeout 30 "$@" 2>&1 | head -4); rc=$?
  if [ -n "$want" ]; then
    echo "$out" | grep -qi -- "$want" && { printf '  \033[32mPASS\033[0m  %s\n' "$name"; PASS=$((PASS+1)); return; }
  elif [ "$rc" = 0 ] && ! echo "$out" | grep -q '✗'; then
    printf '  \033[32mPASS\033[0m  %s\n' "$name"; PASS=$((PASS+1)); return
  fi
  printf '  \033[31mFAIL\033[0m  %-20s %s\n' "$name" "$(echo "$out" | head -1 | cut -c1-66)"
  FAIL=$((FAIL+1)); FAILED+=("$name")
}

$AB open "http://127.0.0.1:9979/" >/dev/null 2>&1; sleep 2

echo "== remaining get / state"
t "get attr"          ""            $AB get attr "#img" alt
t "is enabled"        ""            $AB is enabled "#txt"
t "get count items"   ""            $AB get count ".item"

echo "== remaining find locators"
t "find placeholder"  ""            $AB find placeholder "type here" fill "typed"
t "find label"        ""            $AB find label "Text field" text
t "find testid"       ""            $AB find testid tid text
t "find alt"          ""            $AB find alt "pic" text
t "find title"        ""            $AB find title "tooltip" text
t "find first"        ""            $AB find first ".item" text
t "find last"         ""            $AB find last ".item" text
t "find nth"          ""            $AB find nth 2 ".item" text

echo "== remaining waits"
t "wait --fn"         ""            $AB wait --fn "document.readyState === 'complete'"
$AB click "#slow" >/dev/null 2>&1
t "wait --url"        ""            $AB wait --url "**#done"

echo "== mouse primitives"
t "mouse move"        ""            $AB mouse move 100 100
t "mouse down"        ""            $AB mouse down left
t "mouse up"          ""            $AB mouse up left
t "mouse wheel"       ""            $AB mouse wheel 50

echo "== keyboard primitives"
t "keydown"           ""            $AB keydown Shift
t "keyup"             ""            $AB keyup Shift

echo "== drag / upload"
t "drag"              ""            $AB drag "#src" "#dst"
t "upload"            ""            $AB upload "#file" /tmp/p3-upload.txt

echo "== dialogs"
$AB click "#confirmbtn" >/dev/null 2>&1 &
sleep 1
t "dialog status"     ""            $AB dialog status
t "dialog accept"     ""            $AB dialog accept

echo "== storage / cookies clear"
t "storage clear"     ""            $AB storage local clear
t "cookies clear"     ""            $AB cookies clear

echo "== network detail"
t "network requests --filter" ""    $AB network requests --filter 9979

echo "== tabs / windows lifecycle"
t "window new"        ""            $AB window new
t "tab new"           ""            $AB tab new "http://127.0.0.1:9979/"
t "tab close"         ""            $AB tab close

echo "== react (needs --enable react-devtools at launch; expected unavailable)"
out=$(timeout 20 $AB react tree 2>&1 | head -1)
if echo "$out" | grep -qi "react"; then printf '  \033[32mPASS\033[0m  react tree\n'; PASS=$((PASS+1));
else printf '  \033[33mSKIP\033[0m  react tree (%s)\n' "$(echo "$out"|cut -c1-46)"; SKIP=$((SKIP+1)); fi

echo
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ ${#FAILED[@]} -gt 0 ] && printf 'failed: %s\n' "${FAILED[*]}"
exit 0
