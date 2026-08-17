# demonlock — user guide

A conditional macOS locker. One root daemon watches **where you are, what time it is, and which
Wi‑Fi is nearby**, evaluates a single **allow‑policy** you write, and when you're **out of policy**
it shows a 10‑second countdown and then **force‑closes your GUI apps** (your SSH/tmux sessions
survive, so you can always get back in). It installs **disarmed** — nothing happens until you `arm`.

The point isn't a jail. It's a **commitment device**: day‑to‑day you drop your own admin, and any
*loosening* either needs sudo (which you don't have) or waits out a **baked‑in delay** you can't
shorten without recompiling. Impulse‑you can ask; only calm‑you‑hours‑later actually gets it.

> This page is the guide to **using** demonlock. For internals (the cdhash‑authenticated socket,
> the security proofs, file layout), see [ARCHITECTURE.md](ARCHITECTURE.md).

## Contents
- [Mental model](#mental-model)
- [Quick start](#quick-start)
- [The policy language](#the-policy-language)
- [Arm, disarm, and the lockout](#arm-disarm-and-the-lockout)
- [The sudo model — tighten vs loosen](#the-sudo-model--tighten-vs-loosen)
- [`status` — reading the dashboard](#status--reading-the-dashboard)
- [Everyday commands](#everyday-commands)
- [Subsystems (the request→delay→apply primitives)](#subsystems)
  - [safe-apps](#safe-apps) · [snooze-presets](#snooze-presets) · [password-lockbox](#password-lockbox)
  - [delayed policy / zones changes](#delayed-policy--zones-changes)
- [The admin model — dropping and regaining sudo](#the-admin-model)
- [settings-guard](#settings-guard)
- [Command cheat sheet](#command-cheat-sheet)

---

## Mental model

Four moving parts:

1. **The policy** — a boolean expression that's **true when apps are allowed to run**. You set it
   once with `setpolicy`. Example: *"allowed at the office on weekdays 7am–8pm."*
2. **Zones** — named places (a circle or polygon on a map) your policy can reference by name.
3. **Arming** — enforcement is off until `sudo demonlock arm`. Armed + out of policy = countdown →
   apps closed.
4. **The commitment layer** — you run `nosudo` to drop admin. Now you *can't* casually change the
   policy, disarm, or whitelist a distraction — those need sudo. What you *can* do without sudo is
   **request** the change and wait out a fixed delay (hours), or get admin back the same way via the
   **release valve**. The delays are compiled in; a root edit to the settings file can't shrink them.

Two roles run in the background (installed as launchd jobs): the **enforcerd** root daemon (the only
thing that evaluates and enforces) and a per‑user **agent** (reads Location + Wi‑Fi and draws the
countdown panel). If the agent dies, the daemon gets no sensor data → verdict *unknown* →
**fail‑closed** (it blocks). You can't gain access by killing the agent.

---

## Quick start

Run these as your normal user (the installer already ran `sudo ./install.sh`):

```bash
demonlock perm-ask                 # grant Location + Accessibility to "Demonlock" in System Settings
demonlock scan                     # walk your space; capture nearby Wi‑Fi BSSIDs (Ctrl+C to finish)
demonlock zones                    # opens a map — draw + name your zones (Save now, or Save in 36h)
sudo demonlock setpolicy '(LOCATED_IN_ANY(["office"])) AND TIME_IS_ANY([MTWRF0700-2000])'
demonlock status                   # see exactly how it evaluates right now
sudo demonlock arm                 # enforcement ON
```

Then, when you're ready to commit: `demonlock nosudo` drops your admin. To get it back later you
configure and use the [release valve](#the-admin-model).

- `scan` and `zones` **refuse sudo** — Location belongs to your user, so as root every BSSID is
  redacted. Run them as yourself.
- `arm` and `nosudo` need root but are **passwordless** (they only tighten) — they self‑escalate, so
  you don't type `sudo`.

---

## The policy language

`setpolicy` takes one boolean expression — **the ALLOW condition**. Combine with `AND`, `OR`,
`NOT`, and parentheses. Keywords are case‑insensitive. Three primitives:

| Primitive | True when |
|---|---|
| `LOCATED_IN_ANY(["office", "home"])` | you're inside any named zone |
| `FOUND_IN_NEARBY_BSSID(["a4:97:33:5f:aa:b6"])` | any pinned access‑point hardware address is in range |
| `TIME_IS_ANY([MTWRF0700-2000, *1000-1100])` | now falls in any time window |

**Time windows:** `[days][HHMM-HHMM]`. Days are `M T W R F S U` (**R=Thursday, U=Sunday**) or `*`
for all 7. Times are `0000`–`2400`, and **start must be before end** — no midnight wrap, so split
`2200–0200` into `[*2200-2400]` and `[*0000-0200]`. Multiple windows go in the one list, comma‑
separated. BSSIDs must be full `aa:bb:cc:dd:ee:ff` (6 hex pairs); `scan` hands you a paste‑ready list.

**Three‑valued (fail‑closed) logic.** Every clause is **true / false / unknown**. A clause is
*unknown* when its sensor is missing (no location fix, no Wi‑Fi scan). The final verdict is **ALLOW
only when the whole expression is true**; both *false* and *unknown* **block**. So sabotaging a
sensor can only push a clause toward unknown → block; you can never *gain* access by degrading a
signal. (This is why `NOT LOCATED_IN_ANY(["deleted-zone"])` doesn't suddenly allow everything if you
delete the zone — a missing zone is *unknown*, not *false*.)

**Examples:**
```bash
# office by geofence OR a pinned AP, on weekday working hours:
sudo demonlock setpolicy '(LOCATED_IN_ANY(["office"]) OR FOUND_IN_NEARBY_BSSID(["a4:97:33:5f:aa:b6"])) AND TIME_IS_ANY([MTWRF0700-2000])'

# simplest: allowed at the office, any time:
sudo demonlock setpolicy 'LOCATED_IN_ANY(["office"])'
```

`setpolicy` validates the expression (syntax + every referenced zone must exist + a dry‑run) and
**refuses to install a bad policy**. `demonlock status` then shows the live evaluation tree.

---

## Arm, disarm, and the lockout

- **`sudo demonlock arm`** — enforcement ON. It also clears any active snooze, hard‑resets the
  release valve, and **revokes your admin** (arm is the panic button). Passwordless.
- **`sudo demonlock disarm`** — enforcement OFF. Everything keeps running; the countdown panel still
  *shows* but nothing gets killed.

**What happens out of policy (while armed):** a **10‑second countdown** (the panel floats to front,
menubar goes 🟠→🔴). At zero, the daemon **SIGKILLs** every GUI app that isn't spared:

- **Killed:** every Dock app (including Apple ones like Safari) and every **non‑Apple** menubar
  (accessory) app.
- **Survives:** the demonlock agent itself (so it recovers instantly), **Apple‑signed** menubar
  items (Control Center / Spotlight / Siri — verified by signature, not name), your registered
  [safe‑apps](#safe-apps), and anything without a GUI — **`sshd` and `tmux` live**, so you can always
  SSH in and `sudo demonlock disarm`. No logout, no penalty box.

If the agent is dead and stays gone past ~25s, the daemon falls back to the **nuclear** option —
`killall -9 WindowServer` — which drops you to the login window (rate‑limited so the agent can come
back). `sshd`/`tmux` still survive.

**`demonlock test-lockout`** shows exactly which apps a real lockout would close, as a **dry run**:
```
test-lockout: a real lockout would SIGKILL these 3 app(s):
  • Slack  (pid 5123)
  • Spotify  (pid 5140)
  • Telegram  (pid 5210)
  spared apps, Apple menubar items, and sshd/tmux survive. (A test never does the nuclear WindowServer kill.)

DRY RUN — nothing closed. Re-run with --go to actually close them:
  demonlock test-lockout --go
```

---

## The sudo model — tighten vs loosen

Every command falls into one of three buckets. This is the core of the whole design:

| Kind | Needs | Examples |
|---|---|---|
| **Tighten** (makes enforcement stricter) | **no sudo** | `arm`, `nosudo`, `safe-apps remove`, `snooze-preset invoke`, any `abort` |
| **Loosen now** | **sudo** | `setpolicy`, `disarm`, `snooze`, `safe-apps register`, `snooze-preset add` |
| **Loosen later** (no sudo, but waits out a baked delay) | **the delay** | `delay-set-policy`, `safe-apps delayed-register`, `snooze-preset delayed-add`, `admin-release-valve request` |

Since you run day‑to‑day with **no admin** (`nosudo`), "loosen now" is off the table — every
loosening goes through the delay. Those delay floors/ceilings are **compiled into the binary**
(`Bounds`), and every use re‑clamps into them, so editing the root settings file can't shrink them —
changing a floor means recompiling, which isn't silent.

---

## `status` — reading the dashboard

`demonlock status` (no sudo) is the one screen that shows everything:

```
demonlock
  enforced user : minh
  armed         : ARMED
  phase         : MONITORING
  verdict       : ALLOW
  reason        : in policy
  ssh: user@host  (get in with: ssh host)
  policy        : (LOCATED_IN_ANY(["office"])) AND TIME_IS_ANY([MTWRF0700-2000])

  policy evaluation  (✓ true · ✗ false · · unknown):
    ✓ AND
      ✓ LOCATED_IN_ANY(["office"]) — inside "office"
      ✓ TIME_IS_ANY([MTWRF0700-2000]) — Mon 09:30 ∈ M0700-2000

  location:
    fix 37.7749,-122.4194 ±12m  (3s ago)
```

The evaluation tree marks each clause `✓` true, `✗` false, `·` unknown, with a `— reason` note.
When something's queued or active, extra lines appear: `snooze : SNOOZED until …`, `release valve :
…`, `delayed policy : QUEUED — lands …`, and one‑line summaries for safe‑apps / snooze‑presets /
lockbox. If the daemon isn't running: `demonlock: no state yet — the enforcer isn't running.`

The floating **panel** (drawn by the agent) mirrors this: `● ALLOWED` (green) → `LOCK IN 7s` (red) →
`🔒 LOCKED — closing apps`. Disarmed, it reads `WOULD LOCK IN 7s (DISARMED)`.

---

## Everyday commands

| Command | sudo | What it does |
|---|---|---|
| `demonlock status` | no | the full dashboard above |
| `demonlock scan` | no (refuses root) | live Wi‑Fi scan; on Ctrl+C prints a paste‑ready `FOUND_IN_NEARBY_BSSID([...])` and saves `~/demonlock-bssids.txt` |
| `demonlock zones` | no (refuses root) | map to add/delete zones — each asks **Save now (admin)** or **Save in 36h** |
| `demonlock zones list` | no | text list of zones |
| `demonlock perm-ask` | no | opens the Location + Accessibility panes to grant "Demonlock" |
| `sudo demonlock setpolicy '<expr>'` | yes | set + validate the allow‑policy |
| `sudo demonlock arm` / `disarm` | passwordless / yes | enforcement on / off |
| `demonlock nosudo` | passwordless | drop admin now + close the release valve |
| `sudo demonlock snooze "for 90m" \| "until 0730"` | yes | stand down, then auto re‑arm (capped 18h) |
| `demonlock test-lockout [--go]` | no | preview (or `--go`, perform) the per‑app kill |
| `demonlock settings-guard [dump]` | no | status of the System‑Settings pane guard |

`snooze` is the sudo, right‑now stand‑down; for a no‑sudo scheduled stand‑down use a
[snooze‑preset](#snooze-presets).

---

## Subsystems

All four share the same shape: **no‑sudo verbs drop a marker in a user‑owned inbox; the root daemon
consumes it, stamps the real request time (so a delay can't be backdated), and applies it after the
baked delay.** Each `show` renders an aligned table (`(none)` when empty).

### safe-apps

**What:** the whitelist of apps *spared* from the lockout kill. Only `com.demonlock` is baked in and
unremovable; everything else you register. Two regimes: **A** = a root‑owned bundle (team never
checked — survives losing your Developer ID); **B** = `--no-root-ownership` third‑party app, needs
its real 10‑char Apple **Team ID** (refused for your own team). Browsers + `sh.paseo.desktop` are a
permanent blocklist — never spareable.

| Command | sudo | |
|---|---|---|
| `safe-apps show` | no | the spare list + pending registrations |
| `safe-apps register <bundle-id>` | **yes** | Regime A — just the bundle id |
| `safe-apps register <bundle-id> --no-root-ownership --tid <TEAM>` | **yes** | Regime B (Developer‑ID) |
| `safe-apps delayed-register <bundle-id> [--no-root-ownership --tid <TEAM>]` | no | lands after the delay |
| `safe-apps delayed-register abort <name> \| --all` | no | |
| `safe-apps remove <name>` | no | immediate (tightening) |
| `safe-apps set-delay "<dur>"` | **yes** | tune the delayed‑register delay |

**Delay:** default **24h**, clamped **8h–168h**. `--name` overrides the auto‑derived handle used by
`remove`. Registering the same bundle again just replaces the entry (set‑like by bundle id).

```
SAFE APPS — spared from the lockout kill
  name       bundle id          team        root-req
  ─────────  ─────────────────  ──────────  ────────
  demonlock  com.demonlock      SY64MV22J9  yes
  raycast    com.raycast.macos  RN2XY7GK9M  no

PENDING REGISTRATIONS — land after 24h
  name   bundle id            lands in
  ─────  ───────────────────  ────────
  slack  com.tinyspeck.slack  17h42m
```
(To add a new app: it comes as an idea, you `delayed-register` it, and 24h later — when the impulse
has passed — it's actually spared. Or `sudo … register` if you have admin.)

### snooze-presets

**What:** named "stand down" shortcuts, so you don't retype durations. Each preset has a **target**
(`for 90m` / `until 0500`) and an **invoke‑delay** (the commitment gap before it takes effect). Two
baked defaults: `tonight` (until 0500, 1h delay) and `midnight` (until 0005, 1.5h delay). **One
invocation at a time.**

| Command | sudo | |
|---|---|---|
| `snooze-preset show` | no | presets + pending adds |
| `snooze-preset invoke <name>` | no | stand down after the preset's invoke‑delay, then re‑arm |
| `snooze-preset remove <name>` | no | immediate (tightening) |
| `snooze-preset delayed-add --name <n> --duration "<spec>" --delay "<dur>"` | no | new preset, lands after the add‑delay |
| `snooze-preset delayed-add abort <name> \| --all` | no | |
| `snooze-preset abort` | no | cancel the in‑flight invocation |
| `sudo snooze-preset add --name <n> --duration "<spec>" --delay "<dur>"` | **yes** | add a preset immediately |
| `sudo snooze-preset set-delay "<dur>"` | **yes** | tune the delayed‑add delay |

**Delays:** invoke‑delay per preset **1h–168h**; add‑delay default **48h**, clamped **24h–168h**;
any stand‑down is capped at **18h**.

```
SNOOZE PRESETS
  name      target      invoke-delay  landing in
  ────────  ──────────  ────────────  ──────────
  midnight  until 0005  1h30m         N/A
  tonight   until 0500  1h0m          N/A
```

### password-lockbox

**What:** a delay‑gated store for **arbitrary secrets** (Wi‑Fi passwords, tokens) — **not** your
admin password (admin only comes from the release valve). `unlock` a secret, wait out its per‑entry
delay, and it's copyable for 15 minutes, then auto‑relocks — or relocks the instant you `copy`. The
copy lands on the clipboard as a **concealed** type so clipboard managers don't retain it. Entirely
**no sudo**.

| Command | |
|---|---|
| `password-lockbox show` | names, unlock‑delay, status |
| `password-lockbox add --name <n> --delay "<dur>"` | then paste the secret twice |
| `password-lockbox unlock <name>` | start the per‑entry delay |
| `password-lockbox abort <name>` | cancel a pending unlock / relock now |
| `password-lockbox copy <name>` | if unlocked: copy (concealed) + relock |
| `password-lockbox remove <name>` | delete the entry entirely (removing tightens — no sudo) |

**Delay:** per‑entry, floored at **1h** (no ceiling — you set each one). Unlocked‑but‑never‑copied
secrets auto‑relock after **15 min**. Caps: 4096 bytes/secret, 64 entries.

```
PASSWORD LOCKBOX
  name       unlock-delay  status
  ─────────  ────────────  ────────────────────
  git-token  1h0m          locked
  vault-key  2h0m          unlocking in 43m12s
  wifi-pw    1h0m          UNLOCKED
```

### delayed policy / zones changes

**What:** the no‑sudo way to change the **policy** or **zones** — queue it, and it lands after a set
delay (**default 36h**, tunable per slot). The wait is the commitment: impulse‑you can queue a
loosening; only calm‑you‑later gets it. Re‑queuing only pushes the landing *later*, never sooner.

| Command | sudo | |
|---|---|---|
| `demonlock delay-set-policy "<policy>"` | no | queue a new allow‑policy (validated now and at landing) |
| `demonlock delay-set-policy --status \| --abort` | no | view / cancel the queued policy |
| `sudo demonlock delay-set-policy set-delay "<dur>"` | **yes** | tune the policy landing delay (12h–168h) |
| `demonlock delayzones --status \| --abort` | no | view / cancel a queued zones change |
| `sudo demonlock delayzones set-delay "<dur>"` | **yes** | tune the zones landing delay (12h–168h) |
| (map) **Save in …h** | no | how a zones change is *created* (from `demonlock zones`) |

Immediate `sudo demonlock setpolicy` is the sudo path; `delay-set-policy` is the no‑sudo one. Adding a
zone loosens the policy, and deleting one isn't monotone either, so the **zones map** offers *Save
now (admin)* or *Save in 36h* for both. Queued items show up in `demonlock status`:
```
  delayed policy : QUEUED — lands Tue 2026-08-18 09:14  (35h47m left)
                  (LOCATED_IN_ANY(["office"])) AND TIME_IS_ANY([MTWRF0700-2000])
```

---

## The admin model

Day‑to‑day you hold **no admin**; you get it back only through the delay‑gated valve. There's **no
password stored anywhere** — the root daemon edits the `admin` group directly.

**Drop it:** `demonlock nosudo` (passwordless — it only tightens). Revokes admin now and closes the
valve. `arm` does the same automatically.

**Get it back — the release valve.** First configure it once (needs sudo, so do this *before* you
`nosudo`, or during a grant):

```bash
sudo demonlock admin-release-valve set-gate-policy "IN_POLICY AND TIME_IS_ANY([*1000-1100])"
sudo demonlock admin-release-valve set-delay "30m"
sudo demonlock admin-release-valve set-max-request-duration "1h"
```

- **gate‑policy** — *when* a grant may open (policy syntax, plus `IN_POLICY` = "the main policy
  currently allows"). Above: only during the 10–11am window while you're in policy.
- **delay** — wait after you request before it's eligible. Floor **30m**, no ceiling.
- **max‑request‑duration** — ceiling on how long a grant lasts. Hard ceiling **4h**.

Then, with no sudo:
```bash
demonlock admin-release-valve request "60m"   # ask for 60m of admin
demonlock admin-release-valve status          # phase / countdown / gate eval
demonlock admin-release-valve abort           # cancel a pending request OR end a live grant now
```

The lifecycle: **request** (frozen `eligible-at = now + delay`, can't be backdated or shortened) →
**delay** → once eligible, the first tick the **gate is open** it **grants** admin for your duration
→ auto‑**revokes** at expiry. A repeat request while pending only changes the duration, never the
clock.

While a grant is live you can extend it (this needs sudo, which you only have *because* of the
grant, so it can't bootstrap one):
```bash
sudo demonlock admin-release-valve i-still-need-sudo "for 45m"   # ≤ 1h per call, in-window only
```

Status while granted:
```
  release valve : GRANTED — admin held, 0h38m12s left, then auto-revoked
                  delay 30m · max grant 60m · requested 60m
                  gate-policy: IN_POLICY AND TIME_IS_ANY([*1000-1100])
```

> The auto‑revoke is **anti‑accident, not containment** — a login shell open during a grant may keep
> cached group membership until you log out. The real gate is the *request delay*: you can't get
> sudo on impulse, only after the wait, inside your own gate window.

---

## settings-guard

While armed, demonlock also slams **System Settings** shut the instant a guarded pane is frontmost
(FileVault recovery key, Device Management / Profiles) — so you can't quietly pull a config profile
or grab a recovery key mid‑lockdown. Needs the **Accessibility** grant (`demonlock perm-ask`).

```
demonlock settings-guard          # status: enabled/disabled, triggers, accessibility grant
demonlock settings-guard dump     # the window titles it sees on the current pane
```

---

## Command cheat sheet

```
# setup
demonlock perm-ask · demonlock scan · demonlock zones · demonlock zones list
sudo demonlock setpolicy '<expr>' · demonlock status

# enforce
sudo demonlock arm · sudo demonlock disarm · demonlock nosudo
sudo demonlock snooze "for 90m" | "until 0730" · demonlock test-lockout [--go]

# no-sudo loosen-later
demonlock delay-set-policy "<policy>" [--status|--abort]
demonlock delayzones --status|--abort
demonlock safe-apps show|delayed-register <bid>|remove <name>|delayed-register abort <name>|--all
demonlock snooze-preset show|invoke <name>|delayed-add …|remove <name>|abort
demonlock password-lockbox show|add …|unlock <name>|copy <name>|abort <name>
demonlock admin-release-valve request "<dur>"|status|abort

# sudo loosen-now / config
sudo demonlock setpolicy … · sudo demonlock safe-apps register <bid> [--no-root-ownership --tid <TEAM>]
sudo demonlock snooze-preset add … · sudo demonlock admin-release-valve set-gate-policy|set-delay|set-max-request-duration …
sudo demonlock admin-release-valve i-still-need-sudo "for <dur>"
sudo demonlock <safe-apps|snooze-preset|…> set-delay "<dur>"

# help: `demonlock help`, or `<subsystem> help` (e.g. `demonlock safe-apps help`)
```

Every subsystem has its own `help` (e.g. `demonlock admin-release-valve help`). For the design and
security internals, see **[ARCHITECTURE.md](ARCHITECTURE.md)**.
