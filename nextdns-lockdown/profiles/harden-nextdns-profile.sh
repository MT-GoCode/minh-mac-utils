#!/bin/bash
#
# harden-nextdns-profile.sh — turn a stock NextDNS Apple profile into the
# "hardened" form: strip the signature and inject ServerAddresses (NextDNS
# anycast) so DoH bootstraps even when plaintext port 53 is firewalled.
#
#   ./harden-nextdns-profile.sh ~/Downloads/NextDNS\ \(abc123\).mobileconfig [out.mobileconfig]
#
# Default output: profiles/NextDNS-hardened.mobileconfig (next to this script),
# which is where install.sh caches it. Install the result with `open <out>`
# (it will show as "Unverified" — expected, editing breaks NextDNS's signature).

set -euo pipefail

PB=/usr/libexec/PlistBuddy
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# NextDNS anycast bootstrap IPs — verify against your apple.nextdns.io setup page.
ADDRS=(45.90.28.0 45.90.30.0 2a07:a8c0:: 2a07:a8c1::)

SRC="${1:-}"
OUT="${2:-$SELF_DIR/NextDNS-hardened.mobileconfig}"
[ -n "$SRC" ] && [ -f "$SRC" ] || { echo "usage: $0 <downloaded.mobileconfig> [out.mobileconfig]" >&2; exit 1; }

# Refuse SRC == OUT: `security cms -D -i SRC -o OUT` TRUNCATES OUT to 0 bytes
# before it (then) fails on an unsigned input, which would destroy the source.
# (Reachable as `harden ... profiles/NextDNS-hardened.mobileconfig` with no 2nd arg.)
if [ "$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")" = \
     "$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")" ]; then
    echo "error: input and output are the same file ($SRC) — pass a different output path" >&2
    exit 1
fi

# 1. Strip the PKCS#7 signature -> plain XML plist, via a TEMP file so a failed
#    run never leaves a truncated/partial OUT behind. If the input is already
#    unsigned XML, `security cms -D` fails; fall back to copying it as-is.
TMP="$(mktemp "${TMPDIR:-/tmp}/nextdns-harden.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
if security cms -D -i "$SRC" -o "$TMP" 2>/dev/null && [ -s "$TMP" ]; then
    echo "stripped signature -> $OUT"
else
    cp "$SRC" "$TMP"
    echo "input already unsigned -> copied to $OUT"
fi
# All edits happen on $TMP; $OUT is written only at the very end, so a failure
# anywhere below leaves any existing $OUT untouched (no partial/stale output).

# 2. Sanity: the DNS payload must sit at PayloadContent:0:DNSSettings.
"$PB" -c "Print :PayloadContent:0:DNSSettings:ServerURL" "$TMP" >/dev/null 2>&1 \
    || { echo "error: no DNSSettings:ServerURL at PayloadContent:0 — is this a NextDNS Apple profile?" >&2; exit 1; }

# 3. Inject ServerAddresses (idempotent: delete any existing, then add).
"$PB" -c "Delete :PayloadContent:0:DNSSettings:ServerAddresses" "$TMP" >/dev/null 2>&1 || true
"$PB" -c "Add :PayloadContent:0:DNSSettings:ServerAddresses array" "$TMP" >/dev/null
i=0
for ip in "${ADDRS[@]}"; do
    "$PB" -c "Add :PayloadContent:0:DNSSettings:ServerAddresses:$i string $ip" "$TMP" >/dev/null
    i=$((i+1))
done

# 3b. Rebuild OnDemandRules into the captive-portal-safe form (idempotent).
#     macOS already exempts the captive-portal flow from encrypted DNS and uses
#     the network's plaintext resolver — nextdns-lockdown's pf door keeps that
#     path open, which is the actual fix. These rules just reinforce it:
#       RULE 1 (EvaluateConnection / NeverConnect) — Apple's captive-detection +
#         Private-Relay probe domains ALWAYS use the plaintext resolver, never
#         DoH, so detection can't be starved.
#       RULE 2 (Connect) — encrypted DNS stays ON for everything else.
#     Intentionally NO URLStringProbe/Disconnect fallback: it often wouldn't fire
#     (OnDemand isn't evaluated in the captive half-connected state) and would
#     punch a filtering hole whenever it flapped. DoH is never disabled.
NEVER_DOH_DOMAINS=(
    captive.apple.com
    www.appleiphonecell.com
    mask.icloud.com
    mask-h2.icloud.com
    3gppnetwork.org
    dav.orange.fr
    vvm.mobistar.be
    vvm.mstore.msg.t-mobile.com
    tma.vvm.mone.pan-net.eu
    vvm.ee.co.uk
)
"$PB" -c "Delete :PayloadContent:0:OnDemandRules" "$TMP" >/dev/null 2>&1 || true
"$PB" -c "Add :PayloadContent:0:OnDemandRules array" "$TMP" >/dev/null
# RULE 1 — Apple captive/Private-Relay probe domains: plaintext, never DoH.
"$PB" -c "Add :PayloadContent:0:OnDemandRules:0 dict" "$TMP" >/dev/null
"$PB" -c "Add :PayloadContent:0:OnDemandRules:0:Action string EvaluateConnection" "$TMP" >/dev/null
"$PB" -c "Add :PayloadContent:0:OnDemandRules:0:ActionParameters array" "$TMP" >/dev/null
"$PB" -c "Add :PayloadContent:0:OnDemandRules:0:ActionParameters:0 dict" "$TMP" >/dev/null
"$PB" -c "Add :PayloadContent:0:OnDemandRules:0:ActionParameters:0:DomainAction string NeverConnect" "$TMP" >/dev/null
"$PB" -c "Add :PayloadContent:0:OnDemandRules:0:ActionParameters:0:Domains array" "$TMP" >/dev/null
j=0
for d in "${NEVER_DOH_DOMAINS[@]}"; do
    "$PB" -c "Add :PayloadContent:0:OnDemandRules:0:ActionParameters:0:Domains:$j string $d" "$TMP" >/dev/null
    j=$((j+1))
done
# RULE 2 — DoH for everything else (lockdown stays hard).
"$PB" -c "Add :PayloadContent:0:OnDemandRules:1 dict" "$TMP" >/dev/null
"$PB" -c "Add :PayloadContent:0:OnDemandRules:1:Action string Connect" "$TMP" >/dev/null

# 4. Validate, then atomically publish to $OUT.
plutil -lint "$TMP" >/dev/null
cp "$TMP" "$OUT"
echo "OK: $OUT"
echo "    ServerAddresses: ${ADDRS[*]}"
echo "    captive plaintext domains: ${NEVER_DOH_DOMAINS[*]}"
echo "install with:  open \"$OUT\"   -> approve in System Settings (shows Unverified)"
