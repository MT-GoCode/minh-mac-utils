# stayup

Menu-bar control for **staying fully awake with the lid closed** — `pmset -a disablesleep`,
the one thing caffeinate and Amphetamine can't do (their assertions only defeat *idle*
sleep, and die with the process).

```
bolt        awake with lid closed — ON
bolt.slash  normal sleep
```

Menu: current state · Turn On/Off · Quit. CLI: `stayup on|off|status`. Nothing else — it's just
a reader and a switch for the one setting.

## Why it's predictable (the Amphetamine complaint)

- **The menu always shows the system's real state**, re-read every 3s from `pmset`. There's
  no cached belief to drift: toggle it from a terminal or another tool and the menu follows.
- **No timers, no durations, no silent expiry, no automatic behavior.** It's on until you
  turn it off.
- **The setting survives reboots** (macOS power management owns it, not this app), so the
  menu-bar icon is the honest reminder that it's still on. Quitting the app does *not* turn
  it off — and the app says so rather than pretending otherwise. `stayup off` or uninstall
  restores normal sleep.

> No battery guard: it will keep the Mac awake on battery too. Don't leave it ON in a closed bag.

## Install

```sh
sudo ./install.sh
```

Self-contained: `install.sh` declares a small manifest and sources the shared
`../scripts/install-lib.sh`. It builds + signs (Developer ID, team BULCQM9J2V), deploys
**root-owned** to `/Applications`, installs the `stayup` CLI to `/usr/local/bin`, writes
`/etc/sudoers.d/stayup` granting passwordless `pmset -a disablesleep 1|0` **and nothing
else**, and launches. stayup **registers itself as a demonlock spare at install** (root-owned
Regime A) — demonlock ships no base list, so each app registers into it. Uninstall:
`sudo ./uninstall.sh` (restores normal sleep first).

`./scripts/build.sh` alone just builds+signs into `build/` — it deliberately installs
nowhere, so there's never a second user-owned copy.
