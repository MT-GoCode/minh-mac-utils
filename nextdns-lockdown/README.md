# nextdns-lockdown

Make NextDNS the ONLY way DNS leaves this Mac.

- **Resolver** = the macOS NextDNS **Encrypted-DNS profile** (DoH). It does the filtering.
- **Wall** = this tool. A `pf` ruleset that blocks every *other* DNS path.
- Re-asserted every ~5s by a root watchdog. Fail-closed. Removing it needs sudo (gated by sudome).

## What the wall does

- **Blocks:** public plaintext DNS (53), all DoT/DoQ (853), known DoH resolver IPs, VPN ports, Tor.
- **Allows:** plaintext 53 to your LAN/router **plus whatever gateway/resolver the current network hands you** — learned live each tick (incl. public IPv6 resolvers, common on cellular-backed transit/airport wifi) → **captive portals just work on any network. No travel mode. Nothing to run.**
- **Profile deleted?** Wall flushes the LAN door → no DNS until it's back. Can't bypass by removing the profile.

## Install (fresh Mac)

No Homebrew, no nextdns CLI. Needs: macOS 11+, admin, a NextDNS account.

```bash
git clone git@github.com:MT-GoCode/minh-mac-utils.git
cd minh-mac-utils/nextdns-lockdown

# 1. Get your profile from https://apple.nextdns.io  (signed file in ~/Downloads).
#    Harden it: strips the signature, injects bootstrap ServerAddresses (DoH works
#    even with port 53 blocked), and rebuilds the OnDemand captive-portal rules
#    (Apple/iCloud detection domains stay plaintext; DoH for everything else):
./profiles/harden-nextdns-profile.sh ~/Downloads/NextDNS\ \(YOURID\).mobileconfig
#    -> writes profiles/NextDNS-hardened.mobileconfig

# 2. Install tool + daemon (caches that profile; installs DISARMED):
sudo ./install.sh

# 3. Install BOTH profiles. Run in YOUR shell (NOT sudo), one at a time:
open profiles/NextDNS-hardened.mobileconfig   # shows "Unverified" — expected
open profiles/no-browser-doh.mobileconfig
#    After each: System Settings -> "Profile Downloaded" (TOP of sidebar) -> Install.

# 4. Check, then arm (on stable wifi, NOT mid-travel):
nextdns-lockdown selftest        # disarmed: bypasses OPEN, profiles PASS
sudo nextdns-lockdown arm
nextdns-lockdown selftest        # armed: bypasses CLOSED
```

## Daily commands

```bash
nextdns-lockdown status          # what's on
nextdns-lockdown selftest        # probe every bypass
sudo nextdns-lockdown arm        # wall on   (needs the profile installed)
sudo nextdns-lockdown disarm     # wall off  (emergency escape)
sudo nextdns-lockdown reload     # after editing the INSTALLED /usr/local/etc/nextdns-lockdown/*.txt
                                 # (editing the repo's pf/*.txt does nothing until you re-run install.sh)
```

## Profiles

- **NextDNS profile** = the resolver. REQUIRED. Get from apple.nextdns.io, harden with the script.
  - *Hardened* (see step 1) removes the port-53 bootstrap dependency and reinforces captive handling. Stock profile works too — the captive door bootstraps it. Shows "Unverified" (editing breaks NextDNS's signature) — expected.
- **no-browser-doh.mobileconfig** = forces Secure DNS OFF in Chrome/Edge/Brave/Vivaldi/Opera/Arc/Firefox (each browser has its own; no global switch). Safari has none.
- Removing any profile needs admin/sudo (they're system-scoped).

## Files

```
install.sh  uninstall.sh  permcheck.sh
bin/      nextdns-lockdown  nextdns-lockdownd
pf/       nextdns-lockdown.conf  local-dns.txt  doh-blocklist.txt  tor-dirauth.txt
launchd/  com.nextdnslockdown.enforcerd.plist
profiles/ NextDNS-hardened.mobileconfig  no-browser-doh.mobileconfig  harden-nextdns-profile.sh
```

## Can't be blocked (physics, not laziness)

- Manually querying your own router (`dig @router`) — nothing automatic does it.
- A VPN disguised as plain HTTPS (TCP/443); pluggable-transport Tor.
- A brand-new browser pointed at a CUSTOM DoH IP not in the blocklist.

Self-binding (Ulysses-pact) tool. Strength = the sudo delay, not an absolute wall. Don't over-trust it.
