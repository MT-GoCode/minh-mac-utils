#!/bin/bash
# install.sh — idempotent installer for browser-blitz.
# Safe to run any number of times. `--uninstall` removes everything it created.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.minh.browser-blitz"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BINDIR="${BINDIR:-/opt/homebrew/bin}"
STATE="$HOME/.local/state/browser-blitz"
EXT="$HERE/extension"
NODE="$(command -v node || echo /opt/homebrew/bin/node)"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }

# ---------------------------------------------------------------- uninstall
if [ "${1:-}" = "--uninstall" ]; then
  echo "uninstalling browser-blitz"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST";                 ok "LaunchAgent removed"
  rm -f "$BINDIR/browser-blitz";  ok "CLI removed"
  rm -rf "$STATE";                ok "state removed"
  echo
  echo "Left in place (remove by hand if you want them gone):"
  echo "  $HERE            — the source"
  echo "  the Chrome extension — chrome://extensions → remove 'browser-blitz-bridge'"
  exit 0
fi

echo "browser-blitz install"
echo

# ---------------------------------------------------------------- preflight
[ "$(uname)" = Darwin ] || bad "macOS only"
[ -x "$NODE" ] || bad "node not found (brew install node)"
ok "node $($NODE --version)"
[ -d "/Applications/Google Chrome.app" ] || bad "Chrome not installed"
ok "Chrome $("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --version | awk '{print $3}')"
[ -f "$HERE/shim.js" ] || bad "shim.js missing"
[ -f "$EXT/manifest.json" ] || bad "extension/ missing"

# ------------------------------------------- remove superseded predecessors
# This tool has had two prior names/shapes; tear them all out so nothing double-runs.
for old in com.minh.cdp-shim com.minh.use-my-chromed; do
  if launchctl list 2>/dev/null | grep -q "$old"; then
    launchctl bootout "gui/$(id -u)/$old" 2>/dev/null || true
    launchctl remove "$old" 2>/dev/null || true
    warn "removed obsolete service $old"
  fi
  rm -f "$HOME/Library/LaunchAgents/$old.plist"
done
pkill -f "cdpshim.js" 2>/dev/null || true
pkill -f "umc.daemon" 2>/dev/null || true
for oldbin in use-my-chrome agent-chrome; do
  [ -e "$BINDIR/$oldbin" ] && { rm -f "$BINDIR/$oldbin"; warn "removed obsolete $oldbin"; }
done
rm -rf "$HOME/.local/state/use-my-chrome" 2>/dev/null || true

# ------------------------------------------------------------------ install
mkdir -p "$STATE" "$HOME/Library/LaunchAgents"

if [ ! -d "$HERE/node_modules/ws" ]; then
  ( cd "$HERE" && "$(dirname "$NODE")/npm" install --silent ws >/dev/null 2>&1 )
fi
[ -d "$HERE/node_modules/ws" ] && ok "dependency: ws" || bad "npm install ws failed"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$NODE</string><string>$HERE/shim.js</string></array>
  <key>WorkingDirectory</key><string>$HERE</string>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$STATE/shim.log</string>
  <key>StandardErrorPath</key><string>$STATE/shim.err</string>
</dict>
</plist>
PLIST_EOF
ok "LaunchAgent: $PLIST"

pkill -f "$HERE/shim.js" 2>/dev/null || true
sleep 1
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

chmod +x "$HERE/browser-blitz"
ln -sf "$HERE/browser-blitz" "$BINDIR/browser-blitz"
ok "CLI: $BINDIR/browser-blitz"

up=false
for _ in $(seq 15); do
  sleep 1
  if lsof -nP -iTCP:9334 -sTCP:LISTEN >/dev/null 2>&1; then up=true; break; fi
done
$up && ok "shim listening (extensions 9334, slugs 9340-9399)" || bad "shim did not start — see $STATE/shim.err"

# ------------------------------------------------------------- extension
echo
INSTALLED=$("$NODE" -e '
const fs=require("fs"),path=require("path"),os=require("os");
const base=path.join(os.homedir(),"Library/Application Support/Google/Chrome");
const want=process.argv[1];
let hits=[];
try{
  const ls=JSON.parse(fs.readFileSync(path.join(base,"Local State"),"utf8"));
  for(const dir of Object.keys(ls.profile.info_cache)){
    try{
      const sp=JSON.parse(fs.readFileSync(path.join(base,dir,"Secure Preferences"),"utf8"));
      const ex=(sp.extensions&&sp.extensions.settings)||{};
      if(Object.values(ex).some(e=>String(e.path||"")===want)) hits.push(dir);
    }catch{}
  }
}catch{}
console.log(hits.join(","));
' "$EXT")

if [ -n "$INSTALLED" ]; then
  ok "extension loaded from this path in: $INSTALLED"
  echo "  (if you just changed the source, reload it: chrome://extensions → reload 'browser-blitz-bridge')"
else
  warn "extension not loaded from $EXT in any profile — the one manual step:"
  echo "    1. open chrome://extensions   2. enable Developer mode"
  echo "    3. Load unpacked → $EXT   (do this in each profile you want to drive)"
fi

echo
echo "verify:  browser-blitz status"
echo "use:     browser-blitz start-session --slug work   →  agent-browser --cdp <port> ..."
