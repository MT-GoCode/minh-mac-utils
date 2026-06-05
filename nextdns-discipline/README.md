# nextdns-discipline

Two CLI tools that drive a NextDNS profile's **denylist**/**allowlist** for self-discipline:
`nextdns-block` (user-runnable, can only *block*) and `nextdns-allow` (sudo-only, can *unblock*).
Enforcement is **server-side at NextDNS** — the Mac only pushes list changes via the API. There is
**no daemon and no plist**; the gate is the setuid model on the two binaries.

```bash
nextdns-block instagram.com tiktok.com    # block (no sudo)
nextdns-block -f distractions.txt
sudo nextdns-allow instagram.com          # un-block (admin-gated escape hatch)
nextdns-test --blocked -f distractions.txt
```

## Architecture

One C source (`nextdns_discipline.c`) compiled **twice** — `-DMODE_BLOCK` and `-DMODE_ALLOW` —
into two binaries that differ only in direction. The safety property is enforced **at compile
time**, not by a runtime flag:

- **`nextdns-block`** is installed **setuid-root** (`4711`): any user runs it, it reads the
  root-only API key as root, **drops back to your uid**, then calls the API to *remove from
  allowlist + add to denylist*. The allow code path isn't even compiled in — it can **only
  tighten**.
- **`nextdns-allow`** is `0700 root:wheel`, **not** setuid — a normal user can't even execute it;
  it works only under `sudo`, and the binary also refuses unless `euid==0`. That's the
  Pluckeye/admin-gated loosening path.

Everything is root-owned on purpose: if you could read or rewrite the binaries or the key, the gate
would be meaningless.

## Source files

| File | Role |
|---|---|
| `nextdns_discipline.c` | the whole program (compiled twice via `-DMODE_BLOCK` / `-DMODE_ALLOW`) |
| `install.sh` · `uninstall.sh` · `permcheck.sh` | compile+install+write creds · remove (`--purge` drops creds) · perms audit/fix |
| `nextdns-test` | parallel resolution checker — `0.0.0.0`/empty = BLOCKED, real IP = ALLOWED |

## Install

`sudo ./install.sh` (re-runnable; credentials preserved unless `--reconfigure`/`--key-file`):

1. Creates `/usr/local/etc/nextdns-discipline/` (`0700 root`) and writes your **NextDNS Profile ID
   + API key** to `credentials` (`0600 root:wheel`) via `umask 077` + `mktemp` + atomic `mv`. The
   key is the one manual input; scriptable with `--key-file FILE --profile <id>`.
2. Compiles both binaries in a temp dir (no libcurl — they shell out to system `curl`).
3. Installs `nextdns-block` `4711`, `nextdns-allow` `0700`, `nextdns-test` `0755` into
   `/usr/local/bin` (nuke + reinstall).

## Post-install layout & permissions

| Path | Owner:Group | Mode | What |
|---|---|---|---|
| `/usr/local/bin/nextdns-block` | root:wheel | **4711** | setuid-root, **execute-only** for non-root (can run, can't read) |
| `/usr/local/bin/nextdns-allow` | root:wheel | **0700** | not setuid ⇒ non-root can't even execute; sudo-only |
| `/usr/local/bin/nextdns-test` | root:wheel | 0755 | resolution test (no secrets) |
| `/usr/local/etc/nextdns-discipline/` | root:wheel | 0700 | creds dir — non-root can't `stat` inside |
| `/usr/local/etc/nextdns-discipline/credentials` | root:wheel | 0600 | `PROFILE=` + `API_KEY=` |

## OS interactions & enforcement

- **setuid privilege model.** `nextdns-block` enters as root only to read the `0600` key (it
  *refuses* unless that file is `uid==0` with no group/other bits), then drops privileges
  **`setgid(getgid())` before `setuid(getuid())`** (correct order) so the network call runs as your
  unprivileged user. `nextdns-allow` never drops — it just demands `euid==0`.
- **Key never leaks.** It's only in the `0600 root` file (not compiled into the unreadable
  binaries) and is handed to `curl` through a **stdin config (`-K -`)**, never argv/env — so it
  can't appear in `ps`. Domains/profile are charset-validated before going into the URL/JSON, so no
  injection.
- **No `PATH` games.** `curl` is invoked by absolute path (`/usr/bin/curl`), after the privilege
  drop.
- **Why no daemon.** Enforcement lives on NextDNS's servers; the Mac just needs to *change* the
  lists, so the local tools are on-demand and persist nothing. Blocks hold regardless of the Mac.

**Propagation:** a `204` commits to your profile instantly but NextDNS takes ~20–30 s to push it to
the resolver, so `nextdns-test` can briefly lag a write. Flush with
`sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`. (Pairs naturally with
**nextdns-lockdown**, which forces all DNS through the local NextDNS resolver so these lists
actually bind.)

## Uninstall

```bash
sudo ./uninstall.sh            # remove the three binaries (keep credentials)
sudo ./uninstall.sh --purge    # also delete /usr/local/etc/nextdns-discipline
sudo ./permcheck.sh [--enforce]
```
