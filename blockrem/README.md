# blockrem

Scheduled, sudo-managed **screen blocks** for forced breaks and reminders. At each scheduled time
a grey opaque cover fills every display with your label and a live countdown, and — with
Accessibility granted — swallows keyboard and mouse for the block's duration. The schedule is
root-owned and the blocker revives itself if you kill it, so a block can't be trivially dismissed;
`snooze` is the sanctioned escape. All times are **local**.

Think "water break every day at 8 AM for 10 minutes" — the machine is unusable for those 10 minutes.

## Install

```sh
sudo ./install.sh          # builds + signs as you (Developer ID ladder), deploys, loads both services
blockrem perm-ask          # grant Accessibility — needed to block keyboard/mouse
```

Uninstall: `sudo ./uninstall.sh` (add `--purge` to also delete the schedule). The visual cover works
without Accessibility; input-blocking needs it (System Settings ▸ Privacy & Security ▸ Accessibility ▸
turn ON **Blockrem**).

## Commands

```
blockrem list                      # all alarms + the active block + any snooze            (no sudo)
blockrem help                                                                              (no sudo)
blockrem perm-ask                  # open Accessibility settings                           (no sudo)

sudo blockrem set --weekly <DAYS|*><HHMM> --label "…" --duration <5-59>
sudo blockrem set --onetime "<for…|at…>"  --label "…" --duration <5-59>
sudo blockrem delete <id>
sudo blockrem snooze "<for…|at…>"  # suppress ALL blocks until that instant
```

`set`, `delete`, and `snooze` require `sudo` (the schedule is the lock). `--label` and `--duration`
are always required; `--duration` is the block **length in SECONDS**, **5–3600** (the 1-hour cap
bounds how long an un-quittable cover can ever sit up). `set` **refuses an alarm whose window would
overlap an existing one** — delete the clashing alarm first.

### `--weekly` — recurring

A single token `<DAYS><HHMM>`: days are `M T W R F S U` (R=Thu, U=Sun) or `*` for every day, then a
4-digit local time.

```sh
sudo blockrem set --weekly *0800   --label "water break" --duration 30   # every day  8:00, 30 sec
sudo blockrem set --weekly MWF1230 --label "lunch — walk" --duration 300 # Mon/Wed/Fri 12:30, 5 min
sudo blockrem set --weekly R1600   --label "stretch"     --duration 60   # Thursdays  16:00, 60 sec
```

### `--onetime` and `snooze` — the instant spec

Both take the same spec, which resolves to a single future **instant** (local):

- `"for <dur>"` — that far from now. Units `d/h/m/s`, combinable: `"for 7h 3s"`, `"for 90m"`, `"for 1h30m"`.
- `"at <HHMM>"` — the next time it's that clock time (today if still ahead, else tomorrow).
- `"at <day>HHMM"` — the next such weekday+time, e.g. `"at U0800"` = next Sunday 08:00.

For `set --onetime`, the instant is **when the block starts** (you still give `--duration` for its
length). One-shot alarms are auto-removed after they finish.

```sh
sudo blockrem set --onetime "at 1400" --label "standup" --duration 120   # next 2 PM, 120 sec
sudo blockrem set --onetime "for 2h"  --label "deep work cutoff" --duration 300  # 2h from now, 5 min
sudo blockrem snooze "for 90m"        # no blocks for 90 minutes
sudo blockrem snooze "at U0800"       # no blocks until Sunday 8 AM
```

(`--duration` is seconds; the `"for 2h"` start spec is a separate thing that takes d/h/m/s.)

## How it works

Two processes from one signed bundle (`com.blockrem`), mirroring demonlock's shape:

- **Root daemon** (`com.blockrem.enforcerd`, LaunchDaemon) — owns `schedule.json`, polls every
  second, prunes finished one-shots, computes the current block (honoring snooze), and publishes
  `active.json`. It also runs a **watchdog**: KeepAlive restarts a crashed agent, and the daemon
  re-bootstraps the agent if you `launchctl bootout` it (which a non-root user can do to their own
  GUI agent).
- **GUI agent** (`com.blockrem.agent`, LaunchAgent, `LSUIElement`) — renders *only* from
  `active.json`: a shield window per display at `CGShieldingWindowLevel` re-maximized every tick, plus
  a `CGEventTap` that swallows input while a block is active. Denies the polite Cmd-Q during a block.

**Fail-open by design** (the opposite of demonlock): if the agent can't read `active.json`, or the
block ends, it lifts the cover and disables the tap. A bug must never trap you — recovery is always
"the block just lifts." Worst case you SSH in from another machine (`sudo blockrem snooze "for 8h"`)
or `sudo ./uninstall.sh`; a session event tap doesn't affect SSH sessions.

## On-disk layout

`/Library/Application Support/Blockrem/`, all `root:wheel` (world-readable so `list` works, root-only
writable = the lock):

| File | Writer | Notes |
|---|---|---|
| `schedule.json` | `set`/`delete` (sudo) | `[Alarm]` |
| `settings.json` | install | per-machine `enforcedUser` |
| `snooze` | `snooze` (sudo) / daemon auto-clear | epoch or `null` |
| `active.json` | daemon, each tick | the agent's only read surface |
| `logs/enforcerd.log` | daemon | |

## Signing

Uses the shared `../sign-identity.sh` ladder: **Developer ID Application** (Apple-rooted, grant
persists, survives cert expiry) → stable self-signed (`Mac Utils Local Signing`) → ad-hoc. Override
with `CODESIGN_IDENTITY="…"`. A prebuilt signed `dist/Blockrem.app` is kept so the folder installs on
a Mac with no Swift toolchain.

## Notes

- The CGEvent tap needs **Accessibility**; without it you get the visual cover only.
- macOS system menubar items (Wi-Fi, battery, Control Center) are unaffected — blockrem never touches
  other processes; it only shields the screen and taps input for the block window.
- Self-test the pure logic with `blockrem _selftest` (parsing + active-window math).
