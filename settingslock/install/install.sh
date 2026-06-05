#!/bin/bash
# settingslock — single-command installer. Run as your normal user (NOT sudo);
# it sudo's internally. Cleans up any prior install, then deploys fresh:
#   detector agent (your GUI session) + root watchdog that keeps it alive.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="$REPO_DIR/install"
BIN_SRC="$REPO_DIR/.build/release/settingslock"

if [ "$(id -u)" -eq 0 ]; then
    echo "Run as your normal user, NOT sudo (signing needs your keychain)." >&2
    exit 1
fi
UID_NUM="$(id -u)"

# Build fresh if you have a Developer ID cert (or no prebuilt). Otherwise deploy a prebuilt
# dist/settingslock — e.g. a Developer-ID-signed binary from a GitHub release (see root README) —
# so it isn't downgraded to self-signed on a Mac without the cert.
HAVE_DEVID="$(security find-identity -p codesigning -v 2>/dev/null | grep -c 'Developer ID Application' || true)"
if [ -f "$REPO_DIR/dist/settingslock" ] && [ "${HAVE_DEVID:-0}" -eq 0 ]; then
    echo "==> [1/3] no Developer ID cert — using prebuilt dist/settingslock (no rebuild)"; BIN_SRC="$REPO_DIR/dist/settingslock"
else
    echo "==> [1/3] build + sign (identity: Developer ID → self-signed → ad-hoc)"; "$INSTALL_DIR/build.sh"
fi
[ -f "$BIN_SRC" ] || { echo "no binary at $BIN_SRC (need Xcode CLT to build, or a prebuilt dist/settingslock)" >&2; exit 1; }

echo "==> [2/3] deploy + load (needs admin) — also cleans up any prior install"
sudo bash -s -- "$BIN_SRC" "$UID_NUM" "$INSTALL_DIR" <<'ROOT'
set -euo pipefail
BIN_SRC="$1"; UID_NUM="$2"; INSTALL_DIR="$3"
BIN="/usr/local/bin/settingslock"
WATCH="com.settingslock.watch"; GUARD="com.settingslock.guard"
LA="/Library/LaunchAgents"; LD="/Library/LaunchDaemons"

# --- nuke any prior install (guard first so it can't re-spawn the watcher) ---
launchctl bootout "system/$GUARD" 2>/dev/null || true
launchctl bootout "gui/$UID_NUM/$WATCH" 2>/dev/null || true
rm -f "$BIN" "$LA/$WATCH.plist" "$LD/$GUARD.plist" /tmp/settingslock-*.log /tmp/settingslock.heartbeat

# --- install binary (built+signed by the user; deploy only, never re-sign) ---
install -o root -g wheel -m 755 "$BIN_SRC" "$BIN"
codesign --verify --strict "$BIN" || { echo "deployed signature invalid"; exit 1; }

# --- armed flag: default ON (you're installing this to block FileVault), but
#     preserved across reinstalls so a reinstall won't silently re-arm a
#     deliberately-disarmed watcher. ---
mkdir -p /usr/local/etc/settingslock
[ -f /usr/local/etc/settingslock/armed ] || printf '1' > /usr/local/etc/settingslock/armed
chown root:wheel /usr/local/etc/settingslock/armed; chmod 644 /usr/local/etc/settingslock/armed

# --- install plists + load atomically ---
install -o root -g wheel -m 644 "$INSTALL_DIR/$WATCH.plist" "$LA/$WATCH.plist"
install -o root -g wheel -m 644 "$INSTALL_DIR/$GUARD.plist" "$LD/$GUARD.plist"
launchctl bootstrap "gui/$UID_NUM" "$LA/$WATCH.plist" 2>/dev/null || true
launchctl bootstrap system         "$LD/$GUARD.plist" 2>/dev/null || true
launchctl enable "system/$GUARD" 2>/dev/null || true
launchctl kickstart -k "gui/$UID_NUM/$WATCH" 2>/dev/null || true
launchctl kickstart -k "system/$GUARD"       2>/dev/null || true
launchctl print "system/$GUARD" >/dev/null 2>&1 || { echo "guard failed to load"; exit 1; }
echo "   deployed + loaded: watch (gui) + guard (system)"
ROOT

echo "==> [3/3] grant Accessibility (one-time, REQUIRED)"
cat <<EOF

settingslock is installed and running — but it's BLIND until you grant it
Accessibility (that's how it reads the window title):

  System Settings ▸ Privacy & Security ▸ Accessibility
  → turn on (or add with +)  /usr/local/bin/settingslock

(Granting happens on the Accessibility sub-pane, which the watcher ignores, so
it won't fight you. Before the grant it can't detect anything, so it also won't.)

Test after granting: open System Settings → FileVault → it should slam shut.

  settingslock status   # is the watcher running?
  settingslock dump      # show what it sees on the current pane (trigger tuning)
Uninstall:  sudo $INSTALL_DIR/uninstall.sh
EOF
