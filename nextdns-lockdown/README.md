# nextdns-lockdown

Forces **all DNS on this Mac through the local NextDNS resolver** (`127.0.0.1:53`) and keeps it
that way — **fail-closed**, re-asserted by a root watchdog every ~5 s, and gated behind your
Pluckeye/`sudome` admin delay. It makes the local resolver the *only* path DNS can take, so the
blocklist on your NextDNS profile actually holds. Installs **disarmed**.

```bash
sudo ./install.sh             # validates the ruleset (pfctl -n), installs DISARMED
nextdns-lockdown selftest     # check which bypass paths are open/closed
sudo nextdns-lockdown arm     # enforce
sudo nextdns-lockdown disarm  # off (admin-gated, immediate)
sudo nextdns-lockdown travel 15   # captive portal / hotel wifi: allow the gateway DNS for 15 min
```

## Architecture

Your DNS already loops through NextDNS — the problem was nothing *forced* it to:

```
app / Chrome / OS  →  system resolver 127.0.0.1:53  →  nextdns (root daemon)  →  NextDNS (blocklist applied here)
```

That loopback was the *default* resolver but not the *only* one, and `pf` was Disabled, so it could
be sidestepped (alternate DoH/DoT resolvers, a VPN, changing the resolver). Lockdown closes every
side path with **pf** and pins the resolver, fail-closed. Three components:

| Component | launchd | Runs as | Job |
|---|---|---|---|
| `nextdns-lockdownd` | LaunchDaemon `com.nextdnslockdown.enforcerd`, **`system`**, RunAtLoad+KeepAlive | **root** | ~5 s loop: while armed, re-assert the pf ruleset (after `pfctl -n` validation), lock the system resolver to `127.0.0.1` (tighten-only), manage the travel allowance, keep `nextdns` alive; while disarmed, restore default pf once |
| `nextdns-lockdown` | — (on-demand CLI) | root for state changes, any user for reads | `status`/`selftest` (any user), `arm`/`disarm`/`travel`/`reload` (root) |
| the pf ruleset | loaded into the kernel packet filter | — | the actual enforcement (below) |

The **`armed`** flag (root-owned) is the on/off switch the daemon reads each tick.

## Source files

| File | Role |
|---|---|
| `install.sh` · `uninstall.sh` · `permcheck.sh` | root installer (validates, installs disarmed) · remover (`--purge` drops config) · perms audit/fix |
| `bin/nextdns-lockdown` | control + `selftest` CLI |
| `bin/nextdns-lockdownd` | the root watchdog (re-asserts every 5 s) |
| `pf/nextdns-lockdown.conf` | the pf ruleset — **default-pass**, heavily commented |
| `pf/doh-blocklist.txt` | pf table `<doh_resolvers>` — public DoH/DoT resolver IPs |
| `pf/tor-dirauth.txt` | pf table `<tor_dirauth>` — Tor directory authorities |
| `launchd/com.nextdnslockdown.enforcerd.plist` | the LaunchDaemon |

## Install

**Prerequisite:** the homebrew `nextdns` CLI must already be installed and answering on
`127.0.0.1:53` — that loopback resolver is the one lockdown forces all DNS into:
`brew install nextdns/tap/nextdns && sudo nextdns install && sudo nextdns activate`. **`arm`
refuses** unless `dig @127.0.0.1 apple.com` resolves, because locking DNS to a dead resolver would
cause a total, inescapable outage.

`sudo ./install.sh`:

1. Creates `/usr/local/etc/nextdns-lockdown/` (`0700 root`) and copies the pf tables in; seeds the
   `<dns_allow>` table file from `/dev/null`.
2. Installs `nextdns-lockdown` (`0755`) and `nextdns-lockdownd` (`0700`) into `/usr/local/bin`.
3. **Validates the ruleset parse-only** (`pfctl -n -f …`) and refuses to proceed if it doesn't
   parse — a syntax slip *cannot* brick the box.
4. Installs the plist (`0644`) and `bootstrap`s the daemon into `system`. Leaves it **disarmed**.

## Post-install layout & permissions

| Path | Owner:Group | Mode | What |
|---|---|---|---|
| `/usr/local/bin/nextdns-lockdown` | root:wheel | 0755 | control CLI (world-exec, root-owned ⇒ non-root can't modify) |
| `/usr/local/bin/nextdns-lockdownd` | root:wheel | 0700 | watchdog (non-root can't read or run) |
| `/usr/local/etc/nextdns-lockdown/` | root:wheel | 0700 | pf tables + `dns-allow.txt` — non-root can't even read |
| `/Library/LaunchDaemons/com.nextdnslockdown.enforcerd.plist` | root:wheel | 0644 | the daemon job |
| `/Library/Application Support/NextDNSLockdown/` (`armed`, `travel-until`) | root:wheel | 0755 | state (dir not user-writable, so the flag can't be flipped without root) |
| `/var/log/nextdns-lockdown.log` | root:wheel | — | watchdog log |

## OS interactions & enforcement

The ruleset is **default-pass** — it does *not* firewall the machine, it only adds targeted
`block quick` rules, and `set skip on lo0` makes the loopback NextDNS path physically exempt, so
normal TCP 80/443 to ordinary sites is never touched (Chrome resolves through NextDNS exactly as
before). What it blocks (IPv4 **and** IPv6 — the machine is dual-stack):

- **Plain DNS** (UDP/TCP 53) to anything but loopback; **all DoT/DoQ** (853).
- **Known public DoH/DoT resolver IPs** (`<doh_resolvers>`) on **all ports**.
- **Common VPN protocols** (IKEv2/IPSec 500/4500 + ESP/AH, L2TP 1701, OpenVPN 1194, WireGuard
  51820–29, PPTP 1723 + GRE) and **Tor** directory authorities (`<tor_dirauth>`).
- **(Off by default)** QUIC / UDP-443 — ships commented out (resolver IPs are already covered on
  all ports, and blocking UDP/443 adds edge-case latency to QUIC-heavy apps like video calls).
  Enable = uncomment one line + `reload`.

**Self-healing:** a momentary `sudo pfctl -d` or a resolver change (you, DHCP, a VPN) is undone
within ~5 s by the watchdog; `nextdns` is restarted if it dies. **Travel mode** time-boxes a
captive-portal allowance by live-editing the `<dns_allow>` pf table
(`pfctl -t dns_allow -T replace`) for the current gateway, auto-expiring — no full reload, no
disarm.

**Gating / fail-closed:** `arm`/`disarm`/`travel`/`reload` require root ⇒ admin ⇒ Pluckeye/`sudome`
delay. The `armed` flag is `root:wheel` in a non-user-writable dir, so it can't be flipped without
root. State is root-owned; non-root can't read the tables or run the daemon.

**Design decisions worth knowing (don't undo these):**
- **`block`, not pf `rdr`-redirect, for DNS** — `rdr` doesn't reliably catch locally-originated
  traffic; `block out` is reliable + fail-closed (apps hardcoded to external DNS fail, intended).
- **⚠️ NEVER add NextDNS's anycast `45.90.28.0/24` / `45.90.30.0/24` to `doh-blocklist.txt`** —
  that's the *local resolver's own upstream*; blocking it self-DoSes all DNS. Blocking port 53 is
  safe *for* `nextdns` because it talks 443 DoH upstream.
- **Resolver lock tightens only** — `disarm` removes the firewall but leaves NextDNS as the
  resolver (disarm removes the wall, not the filtering).

**Honest limit:** this is a self-binding (Ulysses-pact) tool, not an absolute wall. Its strength
*is* the admin delay — a determined user *with* admin can tear it down; the watchdog + Pluckeye
delay make that deliberate, not impulsive. Obfuscated TCP/443 VPNs and pluggable-transport Tor are
not blockable here. Don't over-trust it.

## Maintenance / uninstall

```bash
sudo nextdns-lockdown reload   # after editing /usr/local/etc/nextdns-lockdown/doh-blocklist.txt
sudo ./permcheck.sh [--enforce]
tail -f /var/log/nextdns-lockdown.log
sudo ./uninstall.sh            # remove enforcement + daemon + binaries (keep config)
sudo ./uninstall.sh --purge    # also remove config + state
```
NextDNS itself is untouched; your resolver stays `127.0.0.1`.
