#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_SRC="$DIR/com.user.fadedaemon.plist.template"
PLIST_DST="$HOME/Library/LaunchAgents/com.user.fadedaemon.plist"

chmod +x "$DIR"/*.sh

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# substitute the absolute paths into the plist
sed -e "s|__DIR__|$DIR|g" -e "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"

# (re)load it
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"

# Expose the two triggers on PATH as `fadepause` / `faderesume` (the ~/.local/bin
# convention the other user tools use). This is what lets anything — a hotkey, or
# wtalk — fire them by name without reaching into this folder.
mkdir -p "$HOME/.local/bin"
ln -sf "$DIR/fadepause-trigger.sh"  "$HOME/.local/bin/fadepause"
ln -sf "$DIR/faderesume-trigger.sh" "$HOME/.local/bin/faderesume"
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *)  LINE='export PATH="$HOME/.local/bin:$PATH"'
        grep -qsF "$LINE" "$HOME/.zshrc" 2>/dev/null || printf '\n%s\n' "$LINE" >> "$HOME/.zshrc"
        echo "• added ~/.local/bin to PATH in ~/.zshrc — run: source ~/.zshrc" ;;
esac

echo "Installed and loaded com.user.fadedaemon"
echo "  daemon   : $DIR/fadedaemon.sh"
echo "  triggers : fadepause  (START / a hotkey)   →  $DIR/fadepause-trigger.sh"
echo "             faderesume (STOP  / a hotkey)   →  $DIR/faderesume-trigger.sh"
echo "  logs     : $HOME/Library/Logs/fadedaemon.log"
echo "  plist    : $PLIST_DST"
echo
echo "One-time per browser: View > Developer > Allow JavaScript from Apple Events,"
echo "and approve the Automation prompt on first action. See README.md."
