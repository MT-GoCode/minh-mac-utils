#!/bin/bash
# Refresh the /etc/hosts block holding tailnet MagicDNS names.
#
# With the overlay no longer owning system DNS, *.ts.net names do not resolve: they are not in
# public DNS, so NextDNS correctly returns NXDOMAIN. Tailnet IPs are stable per node, so a pinned
# snapshot works -- it just needs regenerating when nodes are added or removed.
#
# Only MagicDNS names need this. AWS private-hosted-zone records usually ARE published publicly
# (the prod EKS endpoint resolves fine through NextDNS), so do not pin those without checking.
set -euo pipefail
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
[ -x "$TS" ] || TS=$(command -v tailscale)
[ "$(id -u)" -eq 0 ] || { echo "run with sudo (writes /etc/hosts)" >&2; exit 1; }

BLOCK=$("$TS" status --json | python3 -c '
import json,sys
d=json.load(sys.stdin); out=[]
def add(p):
    n=(p.get("DNSName") or "").rstrip(".")
    ips=[i for i in (p.get("TailscaleIPs") or []) if ":" not in i]
    if n and ips and p.get("Online"): out.append((ips[0],n,n.split(".")[0]))
add(d.get("Self") or {})
for p in (d.get("Peer") or {}).values(): add(p)
for ip,fq,sh in sorted(out,key=lambda x:x[1]): print(f"{ip}\t{fq} {sh}")
')
[ -n "$BLOCK" ] || { echo "no online peers found -- is Tailscale connected?" >&2; exit 1; }

cp /etc/hosts "/etc/hosts.bak-nextdns-$(date +%Y%m%d%H%M%S)"
sed -i "" "/# BEGIN nextdns-sidecar pins/,/# END nextdns-sidecar pins/d" /etc/hosts
{
  echo "# BEGIN nextdns-sidecar pins (generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by refresh-tailnet-hosts.sh)"
  echo "# Tailnet MagicDNS names. NextDNS returns NXDOMAIN for *.ts.net -- they are not public."
  echo "$BLOCK"
  echo "# END nextdns-sidecar pins"
} >> /etc/hosts
dscacheutil -flushcache; killall -HUP mDNSResponder
echo "pinned $(echo "$BLOCK" | wc -l | tr -d ' ') tailnet names"
