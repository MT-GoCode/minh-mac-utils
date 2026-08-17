#!/bin/bash
# Shared code-signing ladder (identity picker) for the macOS .app builders (demonlock, wtalk,
# multistreamviewer, stayup, remote-agent-connector). Echoes the chosen identity on STDOUT (a clean single
# line the caller captures); logs the human-readable choice to STDERR.
#
# On Apple Silicon every binary/.app must be signed to run at all. Order, best first:
#   1. $CODESIGN_IDENTITY              — manual override
#   2. "Developer ID Application: …"   — Apple-rooted; TCC grant persists + survives cert expiry
#   3. "Mac Utils Local Signing"       — stable self-signed (created here if missing); grant
#                                        persists across rebuilds, no Apple account needed
#   4. "-"                             — ad-hoc; works, but the TCC grant resets on every rebuild
#
# Run as your normal user (signing needs your login keychain). Re-running is safe/idempotent.
set -uo pipefail

SELF_NAME="Mac Utils Local Signing"
KC="$HOME/Library/Keychains/login.keychain-db"

# 1. explicit override
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    echo ">> codesign identity: \$CODESIGN_IDENTITY override → $CODESIGN_IDENTITY" >&2
    echo "$CODESIGN_IDENTITY"; exit 0
fi

# 2. Developer ID Application (Apple-rooted, best)
DEVID="$(security find-identity -p codesigning -v 2>/dev/null \
         | awk -F'"' '/Developer ID Application/{print $2; exit}')"
if [ -n "$DEVID" ]; then
    echo ">> codesign identity: Developer ID → $DEVID" >&2
    echo "$DEVID"; exit 0
fi

# 3. stable self-signed cert — create it once if absent (openssl → login keychain)
if ! security find-identity -p codesigning -v 2>/dev/null | grep -qF "$SELF_NAME"; then
    echo ">> no Developer ID — creating a stable self-signed identity '$SELF_NAME'…" >&2
    tmp="$(mktemp -d)"
    if openssl req -x509 -newkey rsa:2048 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
            -days 3650 -nodes -subj "/CN=$SELF_NAME" \
            -addext "basicConstraints=critical,CA:FALSE" \
            -addext "keyUsage=critical,digitalSignature" \
            -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1 \
       && openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
            -out "$tmp/id.p12" -passout pass:macutils -name "$SELF_NAME" >/dev/null 2>&1 \
       && security import "$tmp/id.p12" -k "$KC" -P macutils -T /usr/bin/codesign >/dev/null 2>&1; then
        security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
            -k "$(security default-keychain | tr -d ' "')" "$KC" >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp"
fi
if security find-identity -p codesigning -v 2>/dev/null | grep -qF "$SELF_NAME"; then
    echo ">> codesign identity: stable self-signed → $SELF_NAME" >&2
    echo "$SELF_NAME"; exit 0
fi

# 4. ad-hoc (last resort)
echo ">> codesign identity: ad-hoc (no cert — TCC grant resets on each rebuild)" >&2
echo "-"
