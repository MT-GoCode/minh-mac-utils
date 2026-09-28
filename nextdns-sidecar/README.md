# nextdns-sidecar

NextDNS self-discipline in **one Swift binary + one root LaunchDaemon**. It merges the two retired
tools into a single command surface that follows the demonlock sudo convention (tighten = no sudo,
loosen = sudo):

- the **NextDNS list manager** — `domains block / add / delay-add / abort / future` (was `nextdns-discipline`, whose setuid-C trio is gone)
- the **DNS-bypass `pf` lockdown** — `networklockdown arm / disarm / status`, a firewall wall that forces all DNS through your NextDNS Encrypted-DNS (DoH) profile (was `nextdns-lockdown` + its bash `lockdownd`, now a tick inside the daemon)

```bash
sudo ./install.sh                                       # build → install → load. Installs DISARMED.
nextdns-sidecar domains block instagram.com tiktok.com  # block now (no sudo)
sudo nextdns-sidecar domains add instagram.com          # allow now (sudo — loosening)
nextdns-sidecar domains delay-add instagram.com         # allow after the delay (no sudo, lands in ~12h)
nextdns-sidecar networklockdown status                  # wall state
nextdns-sidecar networklockdown arm                     # enforce (no sudo; needs the DoH profile)
sudo nextdns-sidecar networklockdown disarm             # emergency off (sudo)
```

## Architecture

One Mach-O, one job:

| Role | launchd job | Runs as | Job |
|---|---|---|---|
| CLI | — | you / root | drops **owner-checked markers** into a user-owned inbox for the no-sudo (tightening) verbs; runs the loosening/config verbs directly as root under `sudo` |
| `enforcerd` | LaunchDaemon, **`system`** domain | **root** | owns all state + credentials; each tick consumes markers, calls the NextDNS API, applies due delayed-allows, and (while armed) asserts the `pf` ruleset |

**Sudo-gating (the discipline model).** Tightening (`domains block`, `networklockdown arm`) and
read-only (`status`, `domains future`) and delayed requests (`domains delay-add`) need **no sudo** —
the CLI drops a marker and the root daemon does the privileged work. Loosening (`domains add`,
`networklockdown disarm`) and config (`set-delay`) require **sudo** and run as root directly. The
NextDNS credentials stay root-only, so a no-sudo user can never *allow* a domain immediately.

**Marker trust.** The inbox (`/Library/Application Support/NextDNSSidecar/inbox`) is **user-owned**
so the no-sudo verbs can write without sudo; the daemon reads every marker through the shared
`MarkerIO` invariant (`O_NOFOLLOW` + `st_uid == enforcedUID` + regular-file), so a symlink/hardlink
or a foreign uid can't smuggle a request past it.

## Commands

**domains** (the NextDNS denylist/allowlist):

```bash
nextdns-sidecar domains block <domain>...        # block now                       (no sudo, tighten)
sudo nextdns-sidecar domains add <domain>...     # allow now                       (sudo, loosen)
nextdns-sidecar domains delay-add <domain>...    # allow after the delay           (no sudo)
nextdns-sidecar domains abort <domain> | --all   # cancel queued delayed allow(s)  (no sudo, tighten)
nextdns-sidecar domains future                   # list pending delayed allows     (no sudo)
nextdns-sidecar domains test <domain>...         # is it blocked? (also -f FILE, --blocked/--allowed)
```

All of `block` / `add` / `delay-add` / `test` also accept `-f FILE` (one domain per line, `#` comments).
`test` resolves each domain through the **system resolver** (→ DoH → NextDNS) and reports BLOCKED
(`0.0.0.0`/empty) vs ALLOWED; a `/usr/local/bin/nextdns-test` shim aliases it.

`delay-add` lands after the root-configured, baked-clamped delay (default **12h**, range **8h–168h**);
the tag/target is committed at request time and the daemon applies it — no sudo needed then either.
`future` shows only the pending delayed **adds** (the full domain list stays in NextDNS).

**networklockdown** (the `pf` DNS wall):

```bash
nextdns-sidecar networklockdown arm        # enforce               (no sudo, tighten)
sudo nextdns-sidecar networklockdown disarm     # stop enforcing    (sudo, loosen)
nextdns-sidecar networklockdown status     # show state            (no sudo)
nextdns-sidecar networklockdown selftest   # probe bypass vectors  (no sudo)
sudo nextdns-sidecar networklockdown reload     # re-load pf after editing tables (sudo)
```

`arm` **refuses if the NextDNS Encrypted-DNS profile is not installed OR DNS isn't resolving right now**
(mid captive-portal login) — arming blocks every other DNS path, so either would be a total outage.
`disarm` runs as root and tears `pf` down **now** (works even if the daemon is wedged); the DoH profile
is untouched, so DNS keeps being filtered. `selftest` actively probes plain-DNS/DoH/DoT leaks + each
browser's Secure-DNS policy and reports PASS/FAIL against the armed state.

**config:**

```bash
sudo nextdns-sidecar set-delay "12h"     # the delay-add landing delay (clamped 8h–168h)
```

**tailnet names:**

```bash
sudo ./refresh-tailnet-hosts.sh          # re-pin *.ts.net names into /etc/hosts (sudo)
```

See [VPNs / overlay networks](#vpns--overlay-networks-tailscale) for why this is needed.

## Install

`sudo ./install.sh` (installs **disarmed** — nothing is blocked until you arm):

1. **Builds** `swift build -c release` and installs the binary to `/usr/local/bin/nextdns-sidecar` (root:wheel, 0755).
2. **Config dir** `/usr/local/etc/nextdns-sidecar` (root-only, 700): the `pf` ruleset + tables (`nextdns-lockdown.conf`, `doh-blocklist.txt`, `tor-dirauth.txt`, `local-dns.txt`), a `config.json` (`delaySec` = delay-add delay; `enforcedUser` = the uid allowed to drop markers), and `credentials` (0600).
3. **Credentials** — prompts for your **NextDNS Profile ID + API key** on first install (or `--reconfigure` / `--key-file <path>` / `--profile <id>` to change them); kept across runs otherwise.
4. **State dir** `/Library/Application Support/NextDNSSidecar` with a **user-owned `inbox/`** for the no-sudo markers.
5. **Validates** the `pf` ruleset with `pfctl -n` (parse only — never enables `pf` or arms).
6. **Loads** the LaunchDaemon `com.minh.nextdns-sidecar.enforcerd`.
7. **Builds** the hardened resolver profile from your apple.nextdns.io download — **required** on a first
   install (prompted, or `--profile-src <file>`); if a DoH profile is already installed it's kept and the
   prompt is skipped. There is no "skip hardening" — with no profile and no `--profile-src`, install
   refuses (NextDNS is the whole point). Then **checks** (never silently installs) both profiles and
   prints the `open` lines for the missing ones. `arm` is refused until **both** profiles are present.

## Profiles (the captive-portal fix)

Two profiles you approve in **System Settings ▸ General ▸ Device Management** (macOS can't install a
hand-authored profile silently). The installer prints `open "<path>"` for each missing one:

- **`NextDNS-hardened.mobileconfig`** — built by `profiles/harden-nextdns-profile.sh` from the
  `.mobileconfig` you download at <https://apple.nextdns.io>: strips the signature (shows "Unverified" —
  expected), injects NextDNS anycast `ServerAddresses` (so DoH bootstraps with port 53 firewalled), and
  adds `OnDemandRules` that resolve `captive.apple.com` et al. over **plaintext, never DoH** — **this is
  what makes captive portals appear.** The stock profile works too but doesn't handle captive as cleanly.
- **`profiles/no-browser-doh.mobileconfig`** — forces Secure DNS **off** in every Chromium browser +
  Firefox so they can't bypass the system resolver (the `pf` DoH-IP blocklist is only a backstop).
  **`arm` refuses without it** — checked via each installed browser's Secure-DNS policy — so you can't
  arm a half-hardened system where a browser reaches its own DoH.

Then confirm with `nextdns-sidecar networklockdown status` and `... arm`.

## VPNs / overlay networks (Tailscale)

A VPN that installs itself as the **system resolver** defeats everything else here, and costs no sudo
to turn on — on macOS `tailscale set --accept-dns` is a menu-bar click. When that happens every query
leaves over the tunnel: pf never sees a port-53 packet, the DoH profile stays installed and "healthy",
and NextDNS filters nothing while `status` still reads ARMED.

Three things close it:

- **`<local_dns>` no longer grants the overlay.** `local-dns.txt` used to ship `100.64.0.0/10` (which
  contains Tailscale's `100.100.100.100`) and `fc00::/7` (which contains its ULA), and `learnHosts()`
  scraped every nameserver out of `scutil --dns` — including the overlay's — back into the table on
  every tick. The wall granted its own bypass and re-granted it on every tick. Both halves are fixed; the
  v6 half via a `!fd7a:115c:a1e0::/48` exclusion inside `fc00::/7`.
  Dropping `100.64.0.0/10` does **not** break CGNAT networks (Starlink, T-Mobile 5G Home, most hotel
  and airline Wi-Fi all hand out `100.64.x.x`): the static list is only a baseline, and `learnHosts()`
  still adds *this* network's actual gateway and DHCP-advertised resolvers to the door each tick.
  Only the two literal Tailscale addresses are refused, so a CGNAT portal login resolves normally.
- **`arm` refuses** while an overlay owns the default resolver, and `selftest` leads with two checks
  that judge the real property: is an overlay holding the default path, and does `test.nextdns.io`
  say NextDNS is actually answering. It also probes the overlay addresses directly, so a silent
  failure of the table negation can't pass unnoticed.
- **`enforcerd` reclaims it.** Detection alone would leave you with a *total DNS outage* (the overlay
  resolver is outside `<local_dns>`, so its queries are dropped and nothing resolves). Instead the
  daemon turns the overlay's DNS back off. It ticks every **1s**, which bounds how long an overlay
  can hold system DNS before it is taken back; recovery is automatic and measured end-to-end at ~3s.

**Tailnet names.** With the overlay no longer resolving, `*.ts.net` MagicDNS names stop resolving —
they are not in public DNS, so NextDNS returns NXDOMAIN. Pin them with `sudo ./refresh-tailnet-hosts.sh`
(re-run when tailnet nodes come or go); tailnet IPs are stable per node. The script is **idempotent**:
it deletes the whole `# BEGIN nextdns-sidecar pins` … `# END nextdns-sidecar pins` block and rewrites
it from a fresh `tailscale status --json`, so nodes that went away are dropped and re-runs never
accumulate duplicates. Lines outside that block are untouched, and it backs `/etc/hosts` up first. Peer connectivity, subnet routes and exit nodes are unaffected (they do not
depend on DNS). Note that AWS *private-hosted-zone* records often ARE published publicly — check with
`dig` before assuming a private-looking name needs a pin.

## Residual bypasses (not closed)

Honest list. All of these predate the overlay work and none are closed by it:

Privilege matters when reading this list. The intended operating posture is a **non-admin account
with no sudo**; several vectors that look open to an admin are closed to that user.

- **The current network's own resolver.** `<local_dns>` allows plaintext 53 to RFC1918 + the learned
  gateway, because captive portals require it. So `dig @<gateway> blocked.example` answers, and this
  needs **no privilege of any kind** — not root, not admin. It is the only residual fully open to a
  non-admin, and it is a deliberate trade for captive-portal access.

  **It is not, however, a way to actually use a blocked site.** `dig` hands back one A record; it does
  not change what the *browser* resolves with. Every subsequent lookup a real page makes — CDN shards,
  image and video hosts, fonts, analytics, XHR/API endpoints, each redirect hop — still goes through
  the system resolver to NextDNS and still gets `0.0.0.0`. A modern page issues dozens of these, so
  what you get is a broken fragment, not the site. Pasting the raw IP into the address bar is worse:
  it breaks TLS SNI and name-based vhost routing, so shared-IP and CDN-fronted hosts (which is nearly
  all of them) return the wrong site or a certificate error. Treat this as a leak of individual DNS
  answers, not as a usable browsing bypass — closing it would buy less than its cost to captive
  portals, which is why it stays open.
- **A local DoH forwarder.** `set skip on lo0` exempts loopback entirely and `<doh_resolvers>` only
  lists *known* public resolvers, so a `cloudflared`/`dnscrypt-proxy` on `127.0.0.1:53` forwarding to
  an unlisted DoH endpoint is a complete bypass — but binding a port below 1024 is **root-only**
  (verified: `EACCES` even as an admin user), so this costs sudo and is not a no-privilege vector.
  What *is* free is resolving a name by hand against an unlisted DoH endpoint over 443 and browsing
  by IP; in practice that breaks on any vhosted/CDN site, so it is a nuisance rather than a bypass.
- **Sabotaging the reclaim.** `/Applications` is `root:admin` and mode `rwxrwxr-x`, so an **admin**
  can move `Tailscale.app` aside, flip `--accept-dns=true` and leave the overlay owning DNS. Tested
  end-to-end: the result is a **total DNS outage**, not unfiltered access — the overlay resolvers are
  outside `<local_dns>`, so every fresh query is dropped and the daemon logs an ALERT. Self-punishing,
  and closed outright to a non-admin, who cannot write `/Applications`.
- **A VPN deliberately run over TCP/443.** Indistinguishable from HTTPS; not blockable here.
- **Tor pluggable transports.** Ride CDNs on 443; the `<tor_dirauth>` table is a speed bump only.

## Uninstall

`sudo ./uninstall.sh` (disarms, boots out the daemon, removes the binary + `nextdns-test` shim + pf
ruleset + state; keeps credentials/config unless `--purge`). Remove the two profiles yourself in Device
Management.

## Post-install layout

| Path | Owner | Mode | What |
|---|---|---|---|
| `/usr/local/bin/nextdns-sidecar` | root:wheel | 755 | the binary (CLI + `enforcerd`) |
| `/usr/local/etc/nextdns-sidecar/` | root:wheel | 700 | pf ruleset/tables + `config.json` |
| `/usr/local/etc/nextdns-sidecar/credentials` | root:wheel | **600** | NextDNS Profile ID + API key (never committed) |
| `/Library/Application Support/NextDNSSidecar/inbox/` | **you** | 700 | user-owned marker inbox (no-sudo verbs) |
| `/Library/LaunchDaemons/com.minh.nextdns-sidecar.enforcerd.plist` | root:wheel | 644 | the root daemon |

## Credentials (never in this repo)

The installer scaffolds `/usr/local/etc/nextdns-sidecar/credentials` (root-only, 0600) and you fill in
your NextDNS **Profile ID** + **API key** at the prompt. Nothing secret is committed.
