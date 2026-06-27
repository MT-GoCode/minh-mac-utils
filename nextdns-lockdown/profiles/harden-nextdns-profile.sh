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

# 1. Strip the PKCS#7 signature -> plain XML plist. If it's already unsigned XML,
#    `security cms -D` fails; fall back to copying it as-is.
if security cms -D -i "$SRC" -o "$OUT" 2>/dev/null; then
    echo "stripped signature -> $OUT"
else
    cp "$SRC" "$OUT"
    echo "input already unsigned -> copied to $OUT"
fi

# 2. Sanity: the DNS payload must sit at PayloadContent:0:DNSSettings.
"$PB" -c "Print :PayloadContent:0:DNSSettings:ServerURL" "$OUT" >/dev/null 2>&1 \
    || { echo "error: no DNSSettings:ServerURL at PayloadContent:0 — is this a NextDNS Apple profile?" >&2; exit 1; }

# 3. Inject ServerAddresses (idempotent: delete any existing, then add).
"$PB" -c "Delete :PayloadContent:0:DNSSettings:ServerAddresses" "$OUT" >/dev/null 2>&1 || true
"$PB" -c "Add :PayloadContent:0:DNSSettings:ServerAddresses array" "$OUT" >/dev/null
i=0
for ip in "${ADDRS[@]}"; do
    "$PB" -c "Add :PayloadContent:0:DNSSettings:ServerAddresses:$i string $ip" "$OUT" >/dev/null
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
    mask.icloud.com
    mask-h2.icloud.com
    3gppnetwork.org
    dav.orange.fr
    vvm.mobistar.be
    vvm.mstore.msg.t-mobile.com
    tma.vvm.mone.pan-net.eu
    vvm.ee.co.uk
)
"$PB" -c "Delete :PayloadContent:0:OnDemandRules" "$OUT" >/dev/null 2>&1 || true
"$PB" -c "Add :PayloadContent:0:OnDemandRules array" "$OUT" >/dev/null
# RULE 1 — Apple captive/Private-Relay probe domains: plaintext, never DoH.
"$PB" -c "Add :PayloadContent:0:OnDemandRules:0 dict" "$OUT" >/dev/null
"$PB" -c "Add :PayloadContent:0:OnDemandRules:0:Action string EvaluateConnection" "$OUT" >/dev/null
"$PB" -c "Add :PayloadContent:0:OnDemandRules:0:ActionParameters array" "$OUT" >/dev/null
"$PB" -c "Add :PayloadContent:0:OnDemandRules:0:ActionParameters:0 dict" "$OUT" >/dev/null
"$PB" -c "Add :PayloadContent:0:OnDemandRules:0:ActionParameters:0:DomainAction string NeverConnect" "$OUT" >/dev/null
"$PB" -c "Add :PayloadContent:0:OnDemandRules:0:ActionParameters:0:Domains array" "$OUT" >/dev/null
j=0
for d in "${NEVER_DOH_DOMAINS[@]}"; do
    "$PB" -c "Add :PayloadContent:0:OnDemandRules:0:ActionParameters:0:Domains:$j string $d" "$OUT" >/dev/null
    j=$((j+1))
done
# RULE 2 — DoH for everything else (lockdown stays hard).
"$PB" -c "Add :PayloadContent:0:OnDemandRules:1 dict" "$OUT" >/dev/null
"$PB" -c "Add :PayloadContent:0:OnDemandRules:1:Action string Connect" "$OUT" >/dev/null

# 4. Validate.
plutil -lint "$OUT" >/dev/null
echo "OK: $OUT"
echo "    ServerAddresses: ${ADDRS[*]}"
echo "    captive plaintext domains: ${NEVER_DOH_DOMAINS[*]}"
echo "install with:  open \"$OUT\"   -> approve in System Settings (shows Unverified)"
