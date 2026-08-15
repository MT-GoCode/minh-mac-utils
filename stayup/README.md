# stayup

Menu-bar control for **staying fully awake with the lid closed** — `pmset -a disablesleep`,
the one thing caffeinate and Amphetamine can't do (their assertions only defeat *idle*
sleep, and die with the process).

```
bolt        awake with lid closed — ON
bolt.slash  normal sleep
```

Menu: current state · Turn On/Off · power source + battery % · **Auto-off when unplugged** ·
Quit. CLI: `stayup on|off|status`.

## Why it's predictable (the Amphetamine complaint)

- **The menu always shows the system's real state**, re-read every 3s from `pmset`. There's
  no cached belief to drift: toggle it from a terminal or another tool and the menu follows.
- **No timers, no durations, no silent expiry.** It's on until you turn it off.
- **The setting survives reboots** (macOS power management owns it, not this app), so the
  menu-bar icon is the honest reminder that it's still on. Quitting the app does *not* turn
  it off — and the app says so rather than pretending otherwise. `stayup off` or uninstall
  restores normal sleep.
- **One automatic behavior, and it only ever tightens:** "Auto-off when unplugged" (on by
  default) turns it off the moment you're on battery — the single case where a closed-lid
  awake Mac cooks itself in a bag.

## Install

```sh
sudo ./install.sh
```

Builds + signs (Developer ID, team BULCQM9J2V), deploys **root-owned** to `/Applications`,
installs the `stayup` CLI, writes `/etc/sudoers.d/stayup` granting passwordless
`pmset -a disablesleep 1|0` **and nothing else**, registers the demonlock spare, verifies
it, and launches. Uninstall: `sudo ./uninstall.sh` (restores normal sleep first).

`./scripts/build.sh` alone just builds+signs into `build/` — it deliberately installs
nowhere, so there's never a second user-owned copy.
