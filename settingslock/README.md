# settingslock

Kills **System Settings** the instant the **FileVault recovery-key pane** renders — a
self-discipline guard so you can't read your own recovery key. A user-session watcher polls the
Accessibility tree every 100 ms; a root daemon re-spawns the watcher if you try to unload it.

```bash
./install.sh                  # run as YOU (it self-sudos; needs your login keychain to sign)
# then grant Accessibility to /usr/local/bin/settingslock in System Settings (one-time, manual)
sudo settingslock arm         # enforcement on
sudo settingslock disarm      # off (admin-gated)
settingslock status           # show state
```

## Architecture

One signed Swift binary (`settingslock <mode>`), split across two launchd jobs for a reason:

| Component | launchd | Runs as | Job |
|---|---|---|---|
| `watch` | LaunchAgent `com.settingslock.watch`, **`gui/<uid>`** | **you** | inspects the System Settings UI via the **Accessibility (AX) API** every 100 ms; the instant the recovery-key pane appears, kills System Settings |
| `guard` | LaunchDaemon `com.settingslock.guard`, **`system`**, KeepAlive | **root** | ~1 s loop: if the user has `bootout`'d the watch agent, re-`bootstrap`+`kickstart` it back into `gui/<uid>` |

**Why the split.** The AX API can only inspect another app's UI from a process *in the user's GUI
session* holding a TCC **Accessibility** grant — a root daemon can't do it. But a user can
`launchctl bootout` their own gui agent without admin. So the watcher *must* run as the user, and a
**root** guard exists solely to undo that bootout — that's the entire anti-escape design. The
root-owned **`armed`** flag gates everything (fail-secure: a missing/garbled flag reads as
**armed**).

## Source files

| File | Role |
|---|---|
| `Sources/settingslock/main.swift` | the whole program — modes `watch` / `guard` / `status` / `arm` / `disarm` / `dump` |
| `Package.swift` | SwiftPM manifest (macOS 13+, links AppKit + ApplicationServices) |
| `install.sh` | thin shim → `install/install.sh` |
| `install/install.sh` | real installer — orchestrates sign → build → sudo-deploy → load |
| `install/build.sh` | `swift build -c release` + sign via the shared `../sign-identity.sh` |
| `install/uninstall.sh` | bootout both + remove |
| `install/com.settingslock.{watch,guard}.plist` | the two launchd jobs |

## Install

`./install.sh` (run as **your** user — it self-sudos for the root parts, and needs your login
keychain to sign):

1. Picks the signing identity via the shared `../sign-identity.sh` (Developer ID → stable
   self-signed → ad-hoc; see **Code signing** below) — so the Accessibility grant survives rebuilds.
2. `build.sh` → `swift build -c release` + `codesign --options runtime` (hardened runtime).
3. **(sudo)** copies the binary → `/usr/local/bin/settingslock` (`0755 root`), both plists →
   `/Library/Launch{Agents,Daemons}` (`0644 root`), the `armed` flag → `/usr/local/etc/settingslock`
   (`0644 root`); `bootstrap`s `guard` (system) + `watch` (gui).
4. **Manual, unavoidable:** grant **Accessibility** to `/usr/local/bin/settingslock` in System
   Settings ▸ Privacy & Security ▸ Accessibility — macOS forbids automating this. Until granted the
   watcher runs but is blind.

## Post-install layout & permissions

| Path | Owner:Group | Mode | What |
|---|---|---|---|
| `/usr/local/bin/settingslock` | root:wheel | 0755 | the signed binary (both modes) |
| `/Library/LaunchAgents/com.settingslock.watch.plist` | root:wheel | 0644 | user watcher — `ProgramArguments = [/usr/local/bin/settingslock, watch]` |
| `/Library/LaunchDaemons/com.settingslock.guard.plist` | root:wheel | 0644 | root guard — `[…/settingslock, guard]` |
| `/usr/local/etc/settingslock/armed` | root:wheel | 0644 | the on/off flag (world-readable, root-write-only) |
| `/tmp/settingslock-*.log`, `/tmp/settingslock.heartbeat` | — | — | logs + liveness |

The plists' `ProgramArguments` point at `/usr/local/bin` (install *copies* the binary there, never
a symlink back to source) — so the source folder can be deleted after install.

## OS interactions & enforcement

- **AX polling.** `watch` walks the System Settings accessibility tree at 100 ms cadence; matching
  the recovery-key pane triggers a kill of System Settings before you can read the key.
- **Why a stable self-signed identity.** TCC ties the Accessibility grant to the code's signing
  identity; a stable cert means you grant once and it survives rebuilds (ad-hoc would reset every
  build).
- **The guard's job.** It calls `launchctl print gui/<uid>/com.settingslock.watch` each second; on
  failure it re-`bootstrap`s + `kickstart`s the agent — so a one-shot `launchctl bootout` of the
  watcher self-heals within ~1 s.
- **Gating.** `arm`/`disarm` require `euid==0` (sudo ⇒ admin ⇒ your sudome/Pluckeye delay). The
  `armed` flag is root-owned; no user-writable config exists to weaken it.

**Honest residual hole:** because the watcher must live in the user session, a *scripted, repeated*
`launchctl bootout gui/<uid>/…watch` race could keep it down during the sub-second gaps in the 1 s
guard loop, and the pane could in principle be reached in one of those windows. This is inherent to
anything that inspects the UI from the user session; the guard makes *casual* (one manual unload)
escape ineffective.

## Code signing

Apple Silicon requires a signature to run at all. The installer auto-picks the best identity
(shared `../sign-identity.sh`) and prints which it used:

1. **Developer ID Application** — if one is in your login keychain. Best: Apple-rooted, the TCC
   grant persists across rebuilds, survives cert expiry (secure timestamp). *Get one (optional):*
   a paid Apple Developer account, then Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ ＋ ▸
   Developer ID Application.
2. **Stable self-signed** (`Mac Utils Local Signing`) — created automatically (openssl → login
   keychain) when you have no Developer ID. TCC grant still persists across rebuilds; no Apple
   account needed.
3. **Ad-hoc** — last resort. Works, but the TCC grant resets on every rebuild.

Override with `CODESIGN_IDENTITY="…"`.

## Uninstall

```bash
sudo ./install/uninstall.sh    # bootout guard + watch, remove binary + plists + armed flag
```
