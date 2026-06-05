# sudome

A self-discipline gate that **grants/revokes admin (sudo) for one user**, where granting requires a
password held by someone else (or set as a commitment). It's the keystone of the whole setup: you
remove your own admin day-to-day, and `sudome add` — with the password — is the only clean way
back. **Revoking needs no password** (tightening is always allowed).

```bash
sudome add        # prompts for the held password; if correct, makes you an admin (sudo)
sudome remove     # drops your admin — no password
```

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

The target user is taken from the **real uid** (`getpwuid(getuid())`); the binary *refuses* to run
as root/`sudo`, so you can't aim it at a different account via args or env.

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
