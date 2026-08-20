#!/bin/bash
# install.sh — browser-blitz.
#   CLI on PATH (browser-blitz + bb), the shim as a LaunchAgent, and a check that playwright-cli
#   is present. The shim binds each live session to `playwright-cli -s=<slug>` by itself, so
#   there is nothing to wire up per session.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"           # .../browser-blitz/browser-blitz
EXT="$(cd "$HERE/../extension" 2>/dev/null && pwd || echo "$HERE/../extension")"
LABEL="com.minh.browser-blitz"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$HOME/.local/state/browser-blitz"
STATE_BINDIR_HINT="$STATE/bindir"
NODE="$(command -v node || true)"

if [ -z "${BINDIR:-}" ]; then
  if command -v brew >/dev/null 2>&1; then BINDIR="$(brew --prefix)/bin"
  elif [ -d /opt/homebrew/bin ];   then BINDIR=/opt/homebrew/bin
  else                                  BINDIR=/usr/local/bin
  fi
fi

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }

echo "browser-blitz install"; echo

[ -f "$HERE/browser-blitz" ] || bad "browser-blitz missing"
[ -f "$HERE/shim.js" ]       || bad "shim.js missing"
[ -d "$EXT" ]                || bad "extension/ missing (expected at $EXT)"
[ -n "$NODE" ]               || bad "node not found — brew install node"
ok "node $($NODE --version)"
case "$NODE" in
  *"/.nvm/"*|*"/.asdf/"*|*"/.volta/"*|*"/fnm/"*)
    warn "node lives under a version manager ($NODE) — the LaunchAgent bakes this exact path in,"
    warn "  so upgrading node will crash-loop the shim. Re-run install.sh after any node upgrade." ;;
esac

# ------------------------------------------------------------------ playwright-cli
# The shim shells out to it to bind sessions, and it is what actually drives pages.
if command -v playwright-cli >/dev/null 2>&1; then
  ok "playwright-cli $(playwright-cli --version 2>/dev/null | head -1)"
else
  warn "playwright-cli not found — installing"
  npm install -g @playwright/cli@latest >/dev/null 2>&1 || bad "npm install -g @playwright/cli failed"
  ok "playwright-cli installed"
fi

# ------------------------------------------------------------------ CLI
# Two symlinks, and nothing touches your shell config. `bb` used to be a zsh alias, which meant
# editing ~/.zshrc — and the uninstaller's line arithmetic was off by one, so it deleted whatever
# followed. A symlink works in a new shell immediately, in non-interactive shells and in scripts.
chmod +x "$HERE/browser-blitz"
mkdir -p "$BINDIR" "$STATE"
for n in browser-blitz bb; do
  # Never clobber silently: `bb` is also a real Homebrew formula, and ln -sf would replace it with
  # no warning and no way for uninstall to put it back.
  if [ -e "$BINDIR/$n" ] && [ "$(readlink "$BINDIR/$n" 2>/dev/null)" != "$HERE/browser-blitz" ]; then
    warn "$BINDIR/$n already exists and is not ours — backing it up to $n.before-browser-blitz"
    mv "$BINDIR/$n" "$BINDIR/$n.before-browser-blitz"
  fi
  ln -sf "$HERE/browser-blitz" "$BINDIR/$n"
  ok "CLI: $BINDIR/$n"
done
echo "$BINDIR" > "$STATE_BINDIR_HINT" 2>/dev/null || true
case ":$PATH:" in *":$BINDIR:"*) ;; *) warn "$BINDIR is not on your PATH";; esac

# ------------------------------------------------------------------ dependency
if [ ! -d "$HERE/node_modules/ws" ]; then
  ( cd "$HERE" && npm install --silent ws >/dev/null 2>&1 )
fi
[ -d "$HERE/node_modules/ws" ] && ok "dependency: ws" || bad "npm install ws failed"

# ------------------------------------------------------------------ shim LaunchAgent
mkdir -p "$STATE" "$HOME/Library/LaunchAgents"
SOCK_INO_BEFORE="$(stat -f %i "$STATE/shim.sock" 2>/dev/null || echo 0)"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$NODE</string><string>$HERE/shim.js</string></array>
  <key>WorkingDirectory</key><string>$HERE</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$BINDIR:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
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

# The socket's inode is the one true "THIS instance booted" marker: the shim recreates it only
# after both ports bind. A port probe answers "is anything listening", not "is it ours" — a stray
# shim from another checkout satisfies that while the real one crash-loops on the clash.
up=false
for _ in $(seq 15); do
  sleep 1
  now="$(stat -f %i "$STATE/shim.sock" 2>/dev/null || echo 0)"
  if [ "$now" != "0" ] && [ "$now" != "$SOCK_INO_BEFORE" ]; then up=true; break; fi
done
$up && ok "shim booted (extensions :9334, CDP :9342)" || bad "shim did not start — see $STATE/shim.err"

echo
echo "load the extension:  chrome://extensions -> Developer mode -> Load unpacked -> $EXT"
echo "then:                bb new-session work"
echo "                     playwright-cli -s=work run-code \"async page => await page.goto('https://example.com')\""
echo "logs:                tail -f $STATE/shim.log"
