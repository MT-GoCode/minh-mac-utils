#!/bin/bash
# Shared post-install check for the GUI apps demonlock must SPARE during a lockout
# (demonlock, wtalk, remote-agent-connector, msv2, stayup).
#
#   verify-spare.sh /Applications/Foo.app com.foo.bundleid
#
# It re-implements exactly what demonlock's Sensors.spareVerified() tests, so an install
# either proves it will survive a lockout or says why it won't. Both regimes are reported
# because either one alone is sufficient:
#   A) bundle is ROOT-OWNED and not group/other-writable  → intact signature + identifier
#   B) not root-owned                                     → Apple-anchored + our Team ID
# Exit 0 if at least one regime holds AND the bundle id is in demonlock's spare list.
set -uo pipefail

APP="${1:?usage: verify-spare.sh <app-bundle> <bundle-id>}"
BID="${2:?usage: verify-spare.sh <app-bundle> <bundle-id>}"
TEAM="${TEAM_ID:-BULCQM9J2V}"
SETTINGS="/Library/Application Support/Demonlock/settings.json"
ok=0

[ -e "$APP" ] || { echo "  ✗ $APP is not installed"; exit 1; }

# stat -f%Lp prints OCTAL digits ("755"); force base-8 or the write-bit mask is nonsense.
# Absolute path: PATH may put GNU coreutils stat first, which rejects BSD -f flags.
MODE=$(/usr/bin/stat -f%Lp "$APP"); OWNER=$(/usr/bin/stat -f%u "$APP")
if [ "$OWNER" = "0" ] && [ "$(( 8#$MODE & 8#022 ))" = "0" ]; then
    if codesign --verify -R "=identifier \"$BID\"" "$APP" 2>/dev/null; then
        echo "  ✓ regime A: root-owned (mode $MODE) + intact signature for $BID"
        ok=1
    else
        echo "  ✗ regime A: root-owned but the signature/identifier check FAILED"
    fi
else
    echo "  · regime A: n/a — not root-owned (uid=$OWNER mode=$MODE); run installer with sudo"
fi

if codesign --verify -R \
    "=anchor apple generic and identifier \"$BID\" and certificate leaf[subject.OU] = \"$TEAM\"" \
    "$APP" 2>/dev/null; then
    echo "  ✓ regime B: Developer ID team $TEAM (survives even if ownership slips)"
    ok=1
else
    echo "  ! regime B: not Developer-ID signed by $TEAM — no fallback if ownership slips"
fi

# settings.json MERGES over demonlock's compiled-in default spareApps ("" drops a default),
# so the effective list = compiled defaults (readable as strings in the binary) + overrides.
DEMONLOCK_BIN="/Applications/Demonlock.app/Contents/MacOS/demonlock"
if [ -f "$SETTINGS" ] || [ -x "$DEMONLOCK_BIN" ]; then
    override="(absent)"
    if [ -f "$SETTINGS" ]; then
        override="$(/usr/bin/python3 -c "import json; print(json.load(open('$SETTINGS')).get('spareApps',{}).get('$BID','(absent)'))" 2>/dev/null || echo '(absent)')"
    fi
    if [ "$override" != "(absent)" ] && [ -n "$override" ]; then
        echo "  ✓ listed in demonlock spareApps (settings.json)"
    elif [ "$override" = "" ]; then
        echo "  ✗ dropped from spareApps by a \"\" override in settings.json — killed on lockout"
        ok=0
    elif [ -x "$DEMONLOCK_BIN" ] && grep -aq "$BID" "$DEMONLOCK_BIN"; then
        echo "  ✓ in demonlock's compiled-in default spareApps"
    else
        echo "  ✗ NOT in demonlock spareApps — it WILL be killed on lockout"
        ok=0
    fi
else
    echo "  · demonlock not installed — spare list not checked"
fi

[ "$ok" = "1" ] && echo "  ⇒ demonlock will spare $BID" \
                || echo "  ⇒ WARNING: $BID is NOT protected from the lockout kill"
exit 0   # advisory: never fail an install over this
