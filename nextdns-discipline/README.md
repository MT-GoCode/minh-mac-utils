# nextdns-discipline

Three CLI tools that drive a NextDNS profile's **denylist**/**allowlist** for self-discipline:
`nextdns-block` (user-runnable, can only *block*), `nextdns-allow` (sudo-only, *unblocks now*), and
`nextdns-delay-allow` (no sudo, *unblocks in 12h* — the wait is the gate). Enforcement is
**server-side at NextDNS** — the Mac only pushes list changes via the API. The block/allow gate is the
setuid model on the binaries; the delayed path adds one small root LaunchDaemon that applies due
entries on a timer.

```bash
nextdns-block instagram.com tiktok.com    # block (no sudo)
nextdns-block -f distractions.txt
sudo nextdns-allow instagram.com          # un-block NOW (admin-gated escape hatch)
nextdns-delay-allow instagram.com         # un-block in 12h (no sudo, no admin — commitment device)
nextdns-delay-allow --status              # what's queued + when it lands
nextdns-delay-allow --abort [domain ...]  # cancel a queued allow (no name = all)
nextdns-test --blocked -f distractions.txt
```

## Architecture

One C source (`nextdns_discipline.c`) compiled **three ways** — `-DMODE_BLOCK`, `-DMODE_ALLOW`,
`-DMODE_DELAY_ALLOW` — into binaries that differ only in direction + gating. The safety property is
enforced **at compile time**, not by a runtime flag:

- **`nextdns-block`** is installed **setuid-root** (`4711`): any user runs it, it reads the
  root-only API key as root, **drops back to your uid**, then calls the API to *remove from
  allowlist + add to denylist*. The allow code path isn't even compiled in — it can **only
  tighten**.
- **`nextdns-allow`** is `0700 root:wheel`, **not** setuid — a normal user can't even execute it;
  it works only under `sudo`, and the binary also refuses unless `euid==0`. That's the
  Pluckeye/admin-gated **immediate** loosening path.
- **`nextdns-delay-allow`** is **setuid-root** (`4711`) but never calls the API in the user's hands.
  Running it as a user only **enqueues** `{domain, apply_at=now+12h}` (or `--status`/`--abort`) into
  a root-owned queue in the creds dir — it touches nothing but the queue, and only ever *adds a
  delayed loosening* or *cancels one*. The real API allow happens in `--apply`, which **refuses
  unless the REAL uid is root** (`getuid()==0`) — so the setuid bit doesn't help a user run it; only
  the LaunchDaemon (real root) or `sudo` applies. The 12h wait is the whole gate: impulse-you can
  queue it, only calm-you-12h-later gets it. No admin needed at any point — the commitment is time,
  not a password (mirrors demonlock's `delaysetpolicy` / release valve).

Everything is root-owned on purpose: if you could read or rewrite the binaries, the key, or the
queue, the gate would be meaningless (the queue is `0600 root` inside the `0700 root` creds dir, so a
user can only reach it through the setuid binary — they can't hand-edit an `apply_at` to skip ahead).

## Source files

| File | Role |
|---|---|
| `nextdns_discipline.c` | the whole program (compiled 3× via `-DMODE_BLOCK` / `-DMODE_ALLOW` / `-DMODE_DELAY_ALLOW`) |
| `install.sh` · `uninstall.sh` · `permcheck.sh` | compile+install+write creds+applier daemon · remove (`--purge` drops creds+queue) · perms audit/fix |
| `nextdns-test` | parallel resolution checker — `0.0.0.0`/empty = BLOCKED, real IP = ALLOWED |

## Install

`sudo ./install.sh` (re-runnable; credentials preserved unless `--reconfigure`/`--key-file`):

1. Creates `/usr/local/etc/nextdns-discipline/` (`0700 root`) and writes your **NextDNS Profile ID
   + API key** to `credentials` (`0600 root:wheel`) via `umask 077` + `mktemp` + atomic `mv`. The
   key is the one manual input; scriptable with `--key-file FILE --profile <id>`.
2. Compiles all three binaries in a temp dir (no libcurl — they shell out to system `curl`).
3. Installs `nextdns-block` `4711`, `nextdns-allow` `0700`, `nextdns-delay-allow` `4711`,
   `nextdns-test` `0755` into `/usr/local/bin` (nuke + reinstall).
4. Installs + bootstraps the applier LaunchDaemon `com.nextdns-discipline.delay-allow`
   (`/Library/LaunchDaemons/…`, `644 root:wheel`) which runs `nextdns-delay-allow --apply` every
   60 s (logs to `/var/log/nextdns-delay-allow.log`). The delayed-allow queue lives at
   `/usr/local/etc/nextdns-discipline/delay-allow-queue` (`0600 root`, created on first enqueue).

## Post-install layout & permissions

| Path | Owner:Group | Mode | What |
|---|---|---|---|
| `/usr/local/bin/nextdns-block` | root:wheel | **4711** | setuid-root, **execute-only** for non-root (can run, can't read) |
| `/usr/local/bin/nextdns-allow` | root:wheel | **0700** | not setuid ⇒ non-root can't even execute; sudo-only |
| `/usr/local/bin/nextdns-delay-allow` | root:wheel | **4711** | setuid-root; user enqueue/status/abort, `--apply` real-root-only |
| `/usr/local/bin/nextdns-test` | root:wheel | 0755 | resolution test (no secrets) |
| `/usr/local/etc/nextdns-discipline/` | root:wheel | 0700 | creds dir — non-root can't `stat` inside |
| `/usr/local/etc/nextdns-discipline/credentials` | root:wheel | 0600 | `PROFILE=` + `API_KEY=` |
| `/usr/local/etc/nextdns-discipline/delay-allow-queue` | root:wheel | 0600 | queued `apply_at domain` lines (via the setuid binary only) |
| `/Library/LaunchDaemons/com.nextdns-discipline.delay-allow.plist` | root:wheel | 0644 | applier: runs `--apply` every 60 s |

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
- **Daemon only for the delayed path.** Enforcement lives on NextDNS's servers; block/allow are
  on-demand and persist nothing. The one daemon is the `nextdns-delay-allow` applier — it exists
  because a 12h-delayed allow needs *something* to fire after the wait. It runs `--apply` every 60 s
  as root: reads the queue, applies entries whose `apply_at` has passed (a failed API call is
  retained and retried next tick, fail-closed), and rewrites the queue. It holds no secrets in argv
  and only ever *loosens on schedule* — the `--apply` guard (`getuid()==0`) is what stops a user from
  driving it early through the setuid bit.

**Propagation:** a `204` commits to your profile instantly but NextDNS takes ~20–30 s to push it to
the resolver, so `nextdns-test` can briefly lag a write. Flush with
`sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`. (Pairs naturally with
**nextdns-lockdown**, which forces all DNS through the local NextDNS resolver so these lists
actually bind.)

## Uninstall

```bash
sudo ./uninstall.sh            # boot out the applier daemon + remove all four binaries (keep creds+queue)
sudo ./uninstall.sh --purge    # also delete /usr/local/etc/nextdns-discipline (creds + queue)
sudo ./permcheck.sh [--enforce]
```
