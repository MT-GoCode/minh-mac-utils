#!/bin/bash
# Shared code-signing ladder (identity picker) for the macOS .app builders (demonlock, wtalk,
# multistreamviewer, stayup, remote-agent-connector). Echoes the chosen identity on STDOUT (a clean single
# line the caller captures); logs the human-readable choice to STDERR.
#
# On Apple Silicon every binary/.app must be signed to run at all. Order, best first:
#   1. $CODESIGN_IDENTITY              — manual override
#   2. "Developer ID Application: …"   — Apple-rooted; TCC grant persists + survives cert expiry
#   3. stable self-signed (hash)       — created here if missing, trusted via trustRoot so `-v` lists it;
#                                        grant persists across rebuilds, no Apple account needed
#   4. "-"                             — ad-hoc; works, but the TCC grant resets on every rebuild
#
# Run as your normal user (signing needs your login keychain). Re-running is safe/idempotent.
set -uo pipefail

SELF_NAME="Mac Utils Local Signing"
KC="$HOME/Library/Keychains/login.keychain-db"

# Echo the SHA-1 hash (not the name) of our self-signed identity. A hash is unambiguous even when a prior
# failed import left a duplicate cert of the same name — signing by name then aborts with "ambiguous".
# Prefer a *valid* (-v) match; fall back to any match. Uses awk (not grep) so an empty result is not fatal.
pick_hash() {
    local h=""
    h="$(security find-identity -p codesigning -v 2>/dev/null | awk -v s="$SELF_NAME" '$0 ~ s {print $2; exit}')"
    [ -n "$h" ] || h="$(security find-identity -p codesigning    2>/dev/null | awk -v s="$SELF_NAME" '$0 ~ s {print $2; exit}')"
    printf '%s' "$h"
}

# Trust an already-imported cert so `find-identity -v` (valid-only) lists it and codesign can use its key
# non-interactively. Without trustRoot a self-signed cert exists but is never "valid" → the ladder would
# wrongly fall through to ad-hoc right after creating it.
ensure_trusted() {
    local tmp; tmp="$(mktemp -d)"
    if security find-certificate -c "$SELF_NAME" -p >"$tmp/c.pem" 2>/dev/null; then
        security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$tmp/c.pem" >/dev/null 2>&1 || true
        security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KC" >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp"
}

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

# 3. stable self-signed cert — create it once if absent, then emit its HASH
HASH="$(pick_hash)"
if [ -z "$HASH" ]; then
    echo ">> no Developer ID — creating a stable self-signed identity '$SELF_NAME'…" >&2
    tmp="$(mktemp -d)"
    # `-legacy` exists only in OpenSSL 3.x. macOS ships LibreSSL, which rejects it outright (dumps
    # usage), breaking the && chain below and silently dropping us to ad-hoc. It is needed ONLY on
    # OpenSSL 3, whose default PBKDF2/AES p12 output `security import` cannot read; LibreSSL already
    # writes the legacy RC2/3DES format. So probe for it rather than assuming Homebrew shadows
    # /usr/bin/openssl.
    LEGACY=""
    openssl pkcs12 -help 2>&1 | grep -q -- '-legacy' && LEGACY="-legacy"
    if openssl req -x509 -newkey rsa:2048 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
            -days 3650 -nodes -subj "/CN=$SELF_NAME" \
            -addext "basicConstraints=critical,CA:FALSE" \
            -addext "keyUsage=critical,digitalSignature" \
            -addext "extendedKeyUsage=critical,codeSigning" 2>"$tmp/openssl.err" \
       && { echo "== step: pkcs12 export" >>"$tmp/openssl.err"; \
            openssl pkcs12 -export $LEGACY -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
              -out "$tmp/id.p12" -passout pass:macutils -name "$SELF_NAME" 2>>"$tmp/openssl.err"; } \
       && { echo "== step: security import" >>"$tmp/openssl.err"; \
            security import "$tmp/id.p12" -k "$KC" -P macutils -T /usr/bin/codesign >/dev/null 2>>"$tmp/openssl.err"; } \
       && { echo "== step: add-trusted-cert (needs an unlocked login keychain + GUI auth)" >>"$tmp/openssl.err"; \
            security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$tmp/cert.pem" >/dev/null 2>>"$tmp/openssl.err"; } \
       && { echo "== step: set-key-partition-list" >>"$tmp/openssl.err"; \
            security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KC" >/dev/null 2>>"$tmp/openssl.err"; }; then
        HASH="$(pick_hash)"
    else
        echo "!! self-signed identity setup failed at: $(awk '/^== step:/{l=$0} END{print (l?l:"== step: openssl req")}' "$tmp/openssl.err" | sed 's/^== step: //')" >&2
        sed 's/^/   /' "$tmp/openssl.err" >&2 2>/dev/null || true
    fi
    rm -rf "$tmp"
else
    # Already present — may be untrusted from an earlier failed run; re-trust so -v and codesign work.
    ensure_trusted
    HASH="$(pick_hash)"
fi
if [ -n "$HASH" ]; then
    echo ">> codesign identity: stable self-signed → $SELF_NAME ($HASH)" >&2
    echo "$HASH"; exit 0
fi

# 4. ad-hoc (last resort)
echo ">> codesign identity: ad-hoc (no cert — TCC grant resets on each rebuild)" >&2
echo "-"
