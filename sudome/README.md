# sudome

A self-discipline gate that **grants/revokes admin (sudo) for one user**, where granting requires a
password held by someone else (or set as a commitment). It's the keystone of the whole setup: you
remove your own admin day-to-day, and `sudome add` — with the password — is the only clean way
back. **Revoking needs no password** (tightening is always allowed).

```bash
sudome add        # prompts for the held password; if correct, makes you an admin (sudo)
sudome remove     # drops your admin — no password

# ROOT-ONLY (no password — root is already the authority). For a root DAEMON (e.g. demonlock's
# scheduled-unlock door) or `sudo`:
sudo sudome --give-to-user  <user>    # grant admin to <user>
sudo sudome --take-from-user <user>   # revoke it
sudo sudome copy-master-password      # copy the held password to the clipboard
```

All three root-only modes are gated on the **real uid** (`getuid()==0`), so only a genuinely
root-invoked caller reaches them — the setuid bit alone (which makes *everyone's* `euid` 0) is not
enough. A normal user still has to use the password-gated `add`. This lets a root process manage a
scheduled/emergency window without the password, while non-root self-service stays gated.

**On `copy-master-password` being root-gated:** handing out the held secret is a *loosening* action,
so it now costs the same authority as `--give-to-user`. Note what this does and doesn't buy you: the
password was never meant to be cryptographically secret *from you* — it's a **portable shared
secret** (the same password gates settings on the phone) and a "make loosening deliberate" marker.
The gate just stops it from being a one-keystroke way to skip the `add` prompt. The real delay-teeth
is Pluckeye; anyone who already has admin can change or undo all of this.

**Eyes open — the state you'll actually be in:** once you've dropped your own admin (the normal
day-to-day state), you have no `sudo`, so you cannot run `copy-master-password` either. That's
intentional: in the locked state the password must come from wherever you're holding it (phone,
partner, sealed note), not from the machine. Don't rely on this command as your recovery path.

## Architecture

A single **setuid-root** C binary (`4711 root:wheel`) — no daemon, no plist. The invoking user can
*execute* it (so it runs as root) but cannot *read* it. It toggles the caller's membership in the
macOS **`admin`** group, which is what grants `sudo` (via the default `%admin ALL=(ALL) ALL`
sudoers rule) and GUI admin elevation.

- **`add`** is password-gated: it reads the expected secret from a root-only file *while root*,
  prompts you (hidden, from `/dev/tty`), compares, and on match runs
  `dseditgroup -o edit -a <user> -t user admin`.
- **`remove`** takes **no** password: `dseditgroup -d` (un-admin) + delete any stale
  `/etc/sudoers.d/sudome-<user>` + wipe cached sudo timestamps.

For `add`/`remove` the target is taken from the **real uid** (`getpwuid(getuid())`) and the binary
*refuses* to run as root/`sudo`, so a non-root user can't aim those at another account. The
`--give-to-user` / `--take-from-user` modes are the inverse: **root-only** (real uid must be 0) and
take an explicit username — so a root daemon (not a normal user) can grant/revoke for a named
account, no password.

## Source files

| File | Role |
|---|---|
| `sudome.c` | the whole program (setuid-root; `add` password-gated, `remove` free) |
| `install.sh` | compile + install `4711`, create the root-only password file |

## Install

`sudo ./install.sh`:

1. Creates `/usr/local/etc/sudome/` (`0700 root`) and an **empty** password file `Allpassword`
   (`0600 root:wheel`) if absent (an existing one is preserved).
2. Compiles `sudome.c` in a temp dir; installs it `-m 4711 root:wheel` (setuid-root, execute-only).
3. **Loudly reminds you to set the password** if it's empty — `add` refuses until you do:
   ```bash
   sudo nano /usr/local/etc/sudome/Allpassword   # secret on the first line, save
   ```

## Post-install layout & permissions

| Path | Owner:Group | Mode | What |
|---|---|---|---|
| `/usr/local/bin/sudome` | root:wheel | **4711** | setuid-root, **execute-only** for non-root (run, can't read) |
| `/usr/local/etc/sudome/` | root:wheel | 0700 | non-root can't `stat` inside |
| `/usr/local/etc/sudome/Allpassword` | root:wheel | 0600 | the held password (one line) |

## OS interactions & enforcement

- **setuid mechanics.** It enters as root to (a) read the `0600` password file — which it *guards*
  by refusing to proceed unless the file is `uid==0` with no group/other bits — and (b) run
  `/usr/sbin/dseditgroup` to edit the `admin` group. No `system()`, no relative paths, no env
  trust; children's stdio go to `/dev/null` so nothing leaks.
- **Admin group → sudo.** Adding you to `admin` grants sudo through macOS's stock `%admin` rule;
  `remove` also `unlink`s any stale `/etc/sudoers.d/sudome-<user>` and clears `/var/db/sudo/ts`
  (the sudo credential cache) so a *fresh* sudo re-prompts immediately.
- **No bypass for a passwordless user.** The secret isn't in source or the (unreadable) binary —
  only in the `0600 root` file; there's no code path to admin without `pw_matches()` returning
  true; the target can't be spoofed (real-uid only). To read or rewrite the password file you'd
  already need root, which needs the password — the loop the tool closes.

**Honest caveats (it's tested + has no bypass, but know these):**
- The password is stored **plaintext** in the root-only file (not hashed) — fine against a
  non-admin you, but a momentary root slip or a disk backup would expose the reusable secret.
- **Revocation lags live sessions:** an already-open shell keeps its cached `admin` group
  membership until you log out, so `remove` is fully effective after logout/login.

## Uninstall

No script — it's two files. To remove:
```bash
sudo rm -f /usr/local/bin/sudome
sudo rm -rf /usr/local/etc/sudome      # also deletes the password
```
(Make sure you're an admin some *other* way first, or you'll lock yourself out of admin.)
