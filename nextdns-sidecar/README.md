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

## Install

`sudo ./install.sh` (installs **disarmed** — nothing is blocked until you arm):

1. **Builds** `swift build -c release` and installs the binary to `/usr/local/bin/nextdns-sidecar` (root:wheel, 0755).
2. **Config dir** `/usr/local/etc/nextdns-sidecar` (root-only, 700): the `pf` ruleset + tables (`nextdns-lockdown.conf`, `doh-blocklist.txt`, `tor-dirauth.txt`, `local-dns.txt`), a `config.json` (`delaySec` = delay-add delay; `enforcedUser` = the uid allowed to drop markers), and `credentials` (0600).
3. **Credentials** — prompts for your **NextDNS Profile ID + API key** on first install (or `--reconfigure` / `--key-file <path>` / `--profile <id>` to change them); kept across runs otherwise.
4. **State dir** `/Library/Application Support/NextDNSSidecar` with a **user-owned `inbox/`** for the no-sudo markers.
5. **Validates** the `pf` ruleset with `pfctl -n` (parse only — never enables `pf` or arms).
6. **Loads** the LaunchDaemon `com.minh.nextdns-sidecar.enforcerd`.
7. **Builds** the hardened resolver profile from your apple.nextdns.io download (prompted, or
   `--profile-src <file>`), then **checks** (never silently installs) both profiles and prints the exact
   `open` lines for the missing ones. `arm` is refused until the DoH profile is present.

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

Then confirm with `nextdns-sidecar networklockdown status` and `... arm`.

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
