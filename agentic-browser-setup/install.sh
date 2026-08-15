#!/usr/bin/env bash
# Install chrome-browser-fleet onto your PATH (symlink into ~/.local/bin), then
# print the two things to set up before first use.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$here/chrome-browser-fleet"
BIN="$HOME/.local/bin"
DEST="$BIN/chrome-browser-fleet"

[ -f "$SRC" ] || { echo "error: $SRC not found" >&2; exit 1; }
mkdir -p "$BIN"
chmod +x "$SRC"
cp "$SRC" "$DEST"           # copy onto PATH (re-run install.sh after editing the script)
chmod +x "$DEST"
echo "installed: $DEST"

case ":$PATH:" in
  *":$BIN:"*) : ;;
  *) echo "note: $BIN is not on your PATH — add it (e.g. in ~/.zshenv)." ;;
esac

cat <<'EOF'

Set up before first use:

1) Install agent-browser (the CDP driver the agent uses to navigate / snapshot / screenshot):
     npm i -g agent-browser && agent-browser install
   Then drive a window by the PORT that new-window prints, e.g.:
     agent-browser --cdp <PORT> snapshot -i
     agent-browser --cdp <PORT> screenshot out.png

2) Create a Chrome profile named exactly "RemoteAgent" (chrome-browser-fleet seeds from it once):
     Google Chrome > profile avatar (top-right) > Add > name it "RemoteAgent",
     then sign into the sites you want the agent to have.

Then use it (a verb is required):
     chrome-browser-fleet new-window "main"             # own Chrome on its own port; prints PORT
     chrome-browser-fleet new-window "bg" --headless
     chrome-browser-fleet state                         # name | port | mode | tabs
     chrome-browser-fleet kill-window "main"
     chrome-browser-fleet --help
EOF
