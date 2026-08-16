#!/bin/bash
# install-all.sh — convenience wrapper that installs every minh-mac-utils tool by running each app's own
# self-contained installer. Run: sudo ./scripts/install-all.sh   (from your NORMAL shell, not a root shell)
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $0"; exit 1; }
: "${SUDO_USER:?run via sudo from your normal user (need SUDO_USER)}"
[ "$SUDO_USER" != root ] || { echo "✗ run as your normal user, not a root shell (SUDO_USER=root)"; exit 1; }
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"

fails=()
root_app() { echo "══════ $1 ══════"; bash "$2" || fails+=("$1"); echo; }
user_app() { echo "══════ $1 ══════"; sudo -u "$SUDO_USER" bash "$2" ${3:-} || fails+=("$1"); echo; }

root_app demonlock              "demonlock/install/install.sh"
root_app msv2                   "msv2/install.sh"
root_app stayup                 "stayup/install.sh"
root_app remote-agent-connector "remote-agent-connector/install.sh"
root_app wtalk                  "wtalk/install/install.sh"
root_app nextdns-sidecar        "nextdns-sidecar/install.sh"     # needs NextDNS creds + the DoH mobileconfig
user_app betterat               "betterat/betterat" install
user_app agentic-browser-setup  "agentic-browser-setup/install.sh"
user_app fade-play-pause-chrome "fade-play-pause-chrome/install.sh"

echo
[ "${#fails[@]}" -eq 0 ] && echo "✓ all installed." || echo "⚠️  finished with failures: ${fails[*]}"
cat <<'STEPS'

════════ MANUAL STEPS STILL NEEDED (installers can't do these for you) ════════
  demonlock   grant permissions:  demonlock perm-ask   (Location + Accessibility), then: demonlock status
  wtalk       add your Gemini key: $EDITOR ~/.wtalk/.env  (GEMINI_API_KEY=…, https://aistudio.google.com/apikey)
              then: wtalk restart   · grant Microphone + Accessibility to "wtalk" in System Settings
  nextdns     the installer asked for your NextDNS key already; now install the DoH profile from
              https://apple.nextdns.io (System Settings ▸ General ▸ Device Management), then:
              nextdns-sidecar networklockdown arm
  rac         edit ~/.remote-agent-connector/config  (MIDDLEMAN, MACHINE_NAME), then: rac setup
  betterat    add ~/.local/bin to PATH if it isn't already (its installer offers to do this)
════════════════════════════════════════════════════════════════════════════
STEPS
