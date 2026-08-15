# demonlock

Conditional macOS locker. One root daemon evaluates a single boolean **policy** over your
location, the time of day, and nearby Wi‑Fi access points; when you're **out of policy** it shows
a 10‑second countdown and then **force-closes your GUI apps** (`sshd`/`tmux` survive, so you can SSH
in to disarm). Replaces `location-locker` + `nightlock` with one signed Swift binary. Installs **disarmed**.

```bash
sudo ./install.sh                 # build (or deploy prebuilt) → sign → install → load. DISARMED.
demonlock scan                    # walk the floor, capture AP hardware addresses (no sudo)
demonlock zones                   # draw/name zones on a map (optional; add=admin, delete=free)
sudo demonlock setpolicy '...'    # set the allow-condition
demonlock status                  # see exactly how it evaluates right now
sudo demonlock arm                # enforcement on
```

## Architecture

One Mach-O, multiplexed by subcommand into two long-running roles:

| Role | launchd job | Runs as | Job |
|---|---|---|---|
| `enforcerd` | LaunchDaemon, **`system`** domain | **root** | the *only* evaluator/enforcer: polls, evaluates the policy, runs the countdown, performs the lockout (force-kills GUI apps, sparing the agent), keeps Wi‑Fi on, writes `state.json` |
| `agent` | LaunchAgent, **`gui/<uid>`** domain | **you** | reads CoreLocation + scans Wi‑Fi BSSIDs (CoreWLAN), feeds them to the daemon over a cdhash-authenticated socket, draws the status/countdown panel |

**Why the split is forced.** macOS delivers CoreLocation / CoreWLAN scan results only to a
*foreground GUI app* holding a TCC Location grant — never to a root daemon ⇒ sensing must live in
the agent. But a logged-in user can `launchctl bootout` their *own* `gui/<uid>` agents without
admin ⇒ the *enforcer* must be a root `system` daemon (needs sudo to stop).

**Trust boundary (the security core).** The daemon accepts location/BSSID data only from a socket
peer whose code-signature **cdhash** matches its own — it pulls the peer's kernel **audit token**
off the unix socket, builds a `SecCode`, and runs `SecCodeCheckValidity` against a
`cdhash H"…"` requirement built from its *own* running code. Because the daemon and agent are the
*same signed binary*, their cdhashes are identical. A killed, modified, or
Location-revoked agent can't feed it ⇒ **fail-closed**. Hardened runtime stops anyone injecting a
fake fix into the live agent.

**Verdict is three-valued (Kleene).** Each clause is true / false / **unknown** (its sensor input
is unavailable). `OR` = true if *any* branch true (even with unknowns); `AND` = false if *any*
false. Verdict **ALLOW** only when the whole expression is true; **BLOCK** on false (out of policy)
*or* unknown (genuinely can't determine). So sabotaging a sensor can only push a clause to
false/unknown, never true — you can never *gain* access by killing the agent.

## Policy language

The ALLOW condition, with `AND` / `OR` / `NOT` / parens and three primitives:

| Function | True when |
|---|---|
| `LOCATED_IN_ANY(["zone", …])` | inside any named zone (circle or simple polygon) |
| `FOUND_IN_NEARBY_BSSID(["aa:bb:cc:dd:ee:ff", …])` | any pinned AP hardware MAC is in range |
| `TIME_IS_ANY([MTWRF0900-1700, *1000-1800, …])` | now ∈ a window — days `M T W R F S U` (R=Thu,U=Sun) or `*`; `HHMM` `0000`–`2400`, `start<end` (no midnight wrap) |

`setpolicy` parses, checks every referenced zone exists, dry-runs, and refuses to install a bad
policy. **BSSID** (AP hardware MAC) is used over the SSID name because names are trivially spoofed;
`scan` flags **stable** hardware APs vs random/virtual ones — pin the stable ones.

## Source files

| File | Role |
|---|---|
| `main.swift` | subcommand dispatch + grouped help |
| `Paths.swift` | every path / launchd label / bundle id (single source of truth) |
| `Settings.swift` · `State.swift` · `Zones.swift` | settings.json, the published `StateSnapshot`/`FeedPayload`/`EvalNode` types + small root files, zone model (circle/polygon, ray-cast) |
| `Policy.swift` | tokenizer → parser → three-valued evaluator → validator (`_policytest` = unit tests) |
| `Feed.swift` | cdhash-authenticated socket server (root) + sender (agent) |
| `Sensors.swift` · `Wifi.swift` | agent CoreLocation + CoreWLAN BSSID feed; root-side Wi‑Fi keep-on |
| `Enforcerd.swift` | the root daemon: poll loop, state machine, lockout (force-kill GUI) |
| `Agent.swift` · `ZonesUI.swift` | status/countdown panel + menubar; the `zones` map program |
| `Commands.swift` | `status`/`setpolicy`/`arm`/`disarm`/`snoozetonight`/`perm-ask`/`_zonedel` |
| `install/` | `build.sh` (codesign), `install.sh`, `uninstall.sh`, `Info.plist`, two `.plist`s |
| `dist/Demonlock.app` | prebuilt, signed bundle so a toolchain-less Mac installs by copy |

## Install

`sudo ./install.sh` (auto-detects what it needs):

1. **Picks the bundle by what you have:** if a **Developer ID cert** is in your login keychain →
   builds + re-signs fresh as `$SUDO_USER` (`swift build -c release` → `codesign --options runtime
   --timestamp`, refreshing `dist/`). **No cert** → deploys the bundled `dist/Demonlock.app`
   (already Developer-ID-signed + timestamped) **without re-signing**, so it isn't downgraded to
   ad-hoc. (Ad-hoc build is the last resort: toolchain but no cert and no `dist/`.) Strips
   quarantine either way.
2. Copies app → `/Applications`, a CLI wrapper → `/usr/local/bin/demonlock`.
3. Seeds `/Library/Application Support/Demonlock/` defaults *only if absent* (`enforcedUser`=
   `$SUDO_USER`, `wifiDevice` auto-detected; `armed=0` ⇒ **installs disarmed**).
4. Installs both plists; writes `/etc/sudoers.d/demonlock` granting passwordless `_zonedel` only.
5. `bootstrap`s `enforcerd` into `system` and `agent` into `gui/$SUDO_UID`; runs `perm-ask` (the
   Location grant — one click, once per machine).

## Post-install layout & permissions

| Path | Owner:Group | Mode | What |
|---|---|---|---|
| `/Applications/Demonlock.app` | root:wheel | 755 | the signed binary (both roles) |
| `/usr/local/bin/demonlock` | root:wheel | 755 | CLI wrapper → app binary |
| `/Library/LaunchDaemons/com.demonlock.enforcerd.plist` | root:wheel | 644 | root daemon (RunAtLoad+KeepAlive) |
| `/Library/LaunchAgents/com.demonlock.agent.plist` | root:wheel | 644 | GUI agent (RunAtLoad+KeepAlive) |
| `…/Demonlock/policy.txt` `zones.json` `settings.json` `armed` `snooze` `state.json` | root:wheel | 644 | config + state — world-readable so `status` works, **root-only writable = the lock** |
| `…/Demonlock/logs/enforcerd.log` | root:wheel | 644 | daemon log |
| `/etc/sudoers.d/demonlock` | root:wheel | 440 | passwordless `demonlock _zonedel *` only (delete tightens) |
| `/var/run/demonlock.sock` | root | 0666 | sensor feed — identity *verified by cdhash*, not access-gated |
| `~/Library/Logs/AllConditionalLocker/agent.log` (or `/tmp/demonlock-agent.log`) | you | 644 | agent log |

(`/Library/Application Support/Demonlock/` is `755 root:wheel`.)

### Moving your zones (and policy) to a new machine

Everything you author lives in `/Library/Application Support/Demonlock/`. The two files worth
carrying over are **`zones.json`** (your named circles/polygons) and **`policy.txt`** (the rule
string). They're plain text, root-owned `644` — readable by anyone, writable only by root. To
clone them onto a freshly-installed Mac:

```bash
# on the OLD machine — grab the files (no sudo needed to read)
cp "/Library/Application Support/Demonlock/zones.json"  ~/Desktop/
cp "/Library/Application Support/Demonlock/policy.txt"  ~/Desktop/

# on the NEW machine — after `sudo ./install.sh` has created the support dir:
sudo cp ~/Desktop/zones.json "/Library/Application Support/Demonlock/zones.json"
sudo demonlock setpolicy "$(cat ~/Desktop/policy.txt)"   # validates names + dry-runs before it lands
```

`sudo cp` is required on the destination because the support dir is root-writable only (that's the
lock). Use `setpolicy` rather than copying `policy.txt` directly so it re-checks every zone name
exists and dry-runs the tree first. The daemon picks up the new `zones.json` on its next tick — no
reload needed.

## OS interactions & enforcement

- **Poll loop.** `enforcerd` ticks immediately, then every `pollSeconds` (1s), tightening to
  `countdownPollSeconds` (0.5s) during a countdown. It only acts when the **console user**
  (`/dev/console` owner) equals `enforcedUser`.
- **Sensing under TCC.** The agent's CoreLocation `authorizedAlways` grant is what un-redacts both
  the location fix *and* CoreWLAN BSSID scans (macOS redacts SSIDs/BSSIDs to any process without a
  Location grant — which is also why `scan` refuses to run as root: root has no grant).
- **Location model: held fix + ONE confidence timer (see `MODEL.md`, the design of record).**
  Macs position from Wi‑Fi only; CoreLocation goes silent when nothing changes, so a fix is **never
  judged by raw age**. The held fix carries one timer, `confirmedUntil`: a genuine new fix, or the
  live scan still overlapping the fix's **BSSID anchor** (per-AP hardware MACs, not network names; ≥1
  shared = still here — moving to a different physical router, even on the same SSID, drops it to zero),
  pushes it `graceSeconds` into the future. While `now < confirmedUntil` the fix is **LIVE** and drives
  the policy; once nothing confirms it — Wi‑Fi off, anchor mismatch, **or the agent dies** — the timer
  runs out → STALE → fail-closed. One timer, every "no signal" case coasts the same. The agent runs
  **foreground (`.regular`, dock icon)** and feeds a rolling union of recent BSSIDs, so a full sweep
  catches both bands of a dual-band router (band-steering can't false-lock you) and an empty window is
  read as real signal-loss. The held fix persists root-owned (`heldfix.json`, heartbeat-rewritten so a
  restart resumes without a false lock) across reboot/sleep — login/wake need no special cases, and the
  user can't forge it.
- **Wi‑Fi keep-on.** While armed, each tick re-enables the radio via `networksetup
  -setairportpower` if it's off — CoreLocation positions from Wi‑Fi, so the radio must stay on.
- **Lockout.** At countdown zero, armed → the root daemon **force-kills the user's GUI apps** every
  tick, **sparing the agent** so it keeps sensing and recovery is instant (back in policy → killing
  stops). If the agent itself is dead, it falls back to `killall WindowServer` (rate-limited). `sshd`/
  `tmux` survive so you can SSH in and `sudo demonlock disarm`. No penalty box; no logout.
- **Fail-closed, but only when it matters.** Stale/missing agent feed, denied Location, missing or
  invalid policy, or a missing `armed` file all resolve to a block *when armed* — but the
  three-valued logic means a still-decidable clause (e.g. an allowed time window, or another zone)
  keeps you allowed. Disarmed = same evaluation, countdown shows, but the lockout is a no-op (title
  reads `(DISARMED)`).
- **Zone changes are asymmetric by privilege.** Adding a zone *loosens* policy → the map UI
  escalates the write via the admin prompt. Deleting *tightens* → passwordless via the narrow
  `_zonedel` sudoers grant (survives you removing your admin rights).
- **Signing.** Developer ID + secure timestamp ⇒ runs on any Mac and stays valid after the cert
  expires; ad-hoc fallback is fully sufficient for the cdhash-trust + hardened-runtime model.

**Residual holes (honest):** OS-level location spoofing needs sudo (disable SIP / attach a
debugger to the hardened agent / tamper the signed app) — all blocked by a no-admin posture;
physical RF BSSID spoofing is exotic but possible. SSIDs are unauthenticated, which is why the
Wi‑Fi check pins BSSIDs.

## Commands & settings

User (no sudo): `status` · `zones` (`view-zones`/`edit-zones` alias it) · `scan` · `perm-ask` ·
`release-valve --request` · `delaysetpolicy "<expr>"` (queue a policy; lands in 36h — `--status`/
`--abort`) · `delayzones --status`/`--abort` (view/cancel a zones change queued from the map) ·
`igotshitdueatmidnight` (in 1.5h, stand down until 12:05 AM tonight, then re-arm — `--status`/
`--abort`) · `help`. Sudo: `setpolicy` · `arm` · `disarm` · `snoozetonight` (stands down until the next
`snoozeHHMM`, default 05:00, then auto-clears; `arm` clears an active snooze) · `snooze "<spec>"`
(flexible stand-down: `"for <duration>"` in d/h/m/s, or `"until <[day]HHMM>"`, e.g. `snooze "for 90m"`
/ `snooze "until 0730"`; **capped at 18 hours**). `snooze` **implies armed and RE-ARMS automatically**
at expiry (no sudo needed then) — so the escape-then-resume flow is just `snooze`, not disarm/arm.
`arm` = enforce now (cancels a snooze); `disarm` = off indefinitely. Settings live in
`settings.json` (`pollSeconds`, `countdownSeconds`, `snoozeHHMM`, `graceSeconds`, `maxAccuracyMeters`,
`scanSeconds`, `scanWindowSeconds`, `enforcedUser` [username **or** uid — the lockout target],
`wifiKeepOn`, `wifiDevice`, `spareApps`). There is deliberately **no fix-age knob** and no
startup-grace knob — a held fix is valid while it keeps being confirmed, never judged by raw age.
See `MODEL.md`.

**Sparing an app from the lockout kill** (`spareApps`): the LOCKED action SIGKILLs **every
`.regular` (Dock) app — including Apple ones like Safari — plus every non-Apple `.accessory`
(menubar) app**, so a distraction repackaged as `LSUIElement` can't dodge the lockout. A `.accessory`
app not in `spareApps` is spared **only if its live signature is genuinely Apple-signed** (`anchor
apple` — which a Developer-ID cert can't satisfy), so Control Center / Spotlight / Siri survive but
an `LSUIElement` distraction stamped `com.apple.…` (or with no bundle id) is killed — the bundle-id
string is never trusted, the signature is verified. This agent is spared by PID. Pure daemons
(betterat, nextdns*) have no GUI app and are never in the kill-list. Everything else dies unless it's
a **verified** entry in `spareApps`.

`spareApps` is `bundle-ID → Team ID`, but an app is spared by **one of two regimes**, picked by
whether its bundle is **root-owned** (`spareVerified` in `Sensors.swift`):

- **Root-owned bundle** (our own apps — demonlock/wtalk/blockrem/foreman-uplink/multistreamviewer
  install to `/Applications` `root:wheel`): spared if it has an **intact signature with the matching identifier — ANY signing
  identity**. No Team ID, no Apple anchor required (`team` is unused here). This means your own apps
  **keep working even if you lose your Developer ID** and fall back to self-signed/ad-hoc. It's safe
  because the adversary has no sudo, so they can't create or modify a root-owned bundle in the first
  place.
- **Not root-owned** (a third-party app, e.g. AltTab/Raycast in `/Applications`): spared only if its
  live signature is **Apple-rooted with the vendor's Team ID** (`anchor apple generic` + that bundle
  id + that Team ID). That's the **vendor's** team — independent of your signing identity — so a
  distraction that merely spoofs a whitelisted bundle id from another signer is still killed, and
  Team (not cdhash) survives the vendor's auto-updates.

Default whitelist: demonlock + wtalk + blockrem + foreman-uplink + multistreamviewer (all ours,
root-owned installs in `/Applications`; wtalk is additionally a PyInstaller-frozen/sealed binary so
it can't be redirected to run other code), plus the third-party AltTab (`com.lwouis.alt-tab-macos`), Raycast
(`com.raycast.macos`), Shottr (`cc.ffitch.shottr`), Amphetamine (`com.if.Amphetamine`), Scroll
Reverser (`com.pilotmoon.scroll-reverser`), BetterDisplay (`pro.betterdisplay.BetterDisplay`), and
Karabiner (`org.pqrs.Karabiner-*`). Both daemon and agent reload settings.json **live** (every tick /
feed), so add your own with no reinstall:

```sh
sudo vi "/Library/Application Support/Demonlock/settings.json"   # "spareApps": {"com.demonlock":"BULCQM9J2V","their.bundle":"TEAMID"}
codesign -dv --verbose=4 /Applications/AltTab.app 2>&1 | grep -E 'Identifier|TeamIdentifier'   # bundle id + Team ID
```

Keep `com.demonlock` in the list. The agent is already spared by PID regardless. Note: a spare only
dodges the per-app kill — the agent-dead nuclear `killall -9 WindowServer` still takes down all GUI.

### To whitelist a new app of yours

Being in `spareApps` is **not** "anything you signed" — it's an explicit per-bundle-id list, AND the
running app must verify (above). A brand-new app you build + sign with your own team is **killed**
unless you do BOTH:

1. Install it **root-owned** in `/Applications` (so the adversary — you, without sudo — can't create
   or modify it). A copy you can write to (e.g. `~/Applications`) is user-owned ⇒ fails the
   root-owned check ⇒ killed even if its bundle id is on the list.
2. Add its bundle id to the list — live, no rebuild:

```sh
sudo vi "/Library/Application Support/Demonlock/settings.json"
#   "spareApps": { "com.demonlock":"BULCQM9J2V", …, "com.minh.newthing":"BULCQM9J2V" }
```

demonlock re-reads that file every ~1 second. Skip either step → it gets killed on lockout.

**Why a self-made `com.demonlock` fake doesn't work:** even though `com.demonlock` is on the list and
you can sign it with your own team, the running impostor would live somewhere you can write
(`~/…`/`~/Applications`) = **user-owned** ⇒ it fails the root-owned check ⇒ killed. The only
`com.demonlock` that's spared is the genuine one installed `root:wheel` in `/Applications` (which took
sudo to put there). And you can't tamper the real one in place — it's root-owned, and editing it
breaks the signature ⇒ also killed.

## Release valve

A **self-serve, delay-gated admin grant** — get sudo back on *your* terms without holding a password
day-to-day. You configure it once (sudo), then `--request` (no sudo); the daemon grants admin only
after a delay and only inside a window you defined, for a fixed duration, then revokes it.

```bash
# configure (sudo; any subset per call):
sudo demonlock release-valve --set-window-policy "IN_POLICY AND TIME_IS_ANY([*1000-1100])"
sudo demonlock release-valve --set-request-delay "12h"      # wait after --request before eligible
sudo demonlock release-valve --set-request-duration "1h"    # how long the grant lasts
# use (no sudo, once all three are set):
demonlock release-valve --request     # granted after the delay, at the next window, for the duration
demonlock release-valve abort         # cancel a pending request / close a live grant now
```

- **`IN_POLICY`** is a new policy primitive, valid **only** in the window policy: it's the main
  policy's current verdict, so you can gate grants on being in-policy (plus any time/location clause).
- **Delay can't be gamed:** `--request` just drops a marker in a **user-owned** inbox
  (`…/Demonlock/rv/`); the **root daemon stamps the request time with its own clock**, so you can't
  backdate to skip the delay or request right before a window.
- **No timers** — config + lifecycle live on disk (root-owned; the inbox is yours), driven by the
  enforcer tick: each tick evaluates the main policy → feeds `IN_POLICY` → evaluates the window
  policy → advances `delay → window → granted → expire`, calling `sudome --give-to-user` /
  `--take-from-user` (idempotent). It grants **admin only** — it does not stand demonlock down, so
  keep `IN_POLICY` in your window policy if you don't want to be locked out during the grant.
- **Notifications** fire on grant and revoke (approve the notification prompt on first agent launch);
  `demonlock status` and the panel show the phase, delay/duration remaining, and the window-eval tree.

## Delayed changes (`delaysetpolicy` + the map's "Save in 36h")

Where the release valve hands back **admin on a delay**, delayed changes hand back the **policy and
zones themselves on a delay** — no sudo, no admin, ever. The gate is purely the **36h wait**: queue a
loosening now, and only calm-you-a-day-and-a-half-later actually gets it. Same trust split as the
valve (root-owned pending state; a user-owned inbox marker; the **daemon stamps the request time**, so
the delay can't be backdated), and the change is **re-validated at apply time** (a zone it referenced
could be gone) — fail-closed if it no longer parses.

```bash
demonlock delaysetpolicy '(LOCATED_IN_ANY(["office"])) AND TIME_IS_ANY([MTWRF0700-2000])'
                                  # queue a NEW allow-policy; lands in 36h (no sudo now OR then)
demonlock delaysetpolicy --status # what's queued + when it lands
demonlock delaysetpolicy --abort  # cancel it
```

Zones ride the **same engine**: in the map (`demonlock zones`), adding a zone loosens the policy, so
on save you're asked **"Save now (admin)"** vs **"Save in 36h"**. *Now* is the existing admin-prompt
path (unchanged); *36h* queues the full new `zones.json` and the daemon installs it after the wait.
View/cancel a queued zones change with `demonlock delayzones --status` / `--abort`.

- **Applies regardless of arm / snooze / who's logged in** — it's a scheduled config change, run at
  the very top of the enforcer tick (before any early return), so this tick's own evaluation already
  sees the freshly-written `policy.txt` / `zones.json`.
- **Re-queueing resets the 36h** (stricter, never shorter). An **alert dialog** (breaks Focus/DnD,
  like the valve) fires when a change lands; `demonlock status` and the panel show what's pending.
- Immediate `sudo demonlock setpolicy` and admin zone-saves are untouched — this only *adds* a
  no-sudo, delayed path alongside them.

### `igotshitdueatmidnight` — a delayed snooze until 12:05 AM

A no-sudo snooze on the same delay model: `demonlock igotshitdueatmidnight` requests it, and **1.5h
later** the daemon stands enforcement down until **12:05 AM tonight**, then re-arms (like
`snoozetonight`, just delayed + no sudo). The 1.5h wait is the whole friction — you eat the lockout
until it's up (ask at 8:30 PM, get locked out at 9:00, relief lands at 10:00), and it kicks in **even
mid-lockout** (the snooze is written at the top of the tick, so that same tick clears the countdown).

- The **12:05 AM target is frozen at request time**, so asking within 1.5h of midnight fails **closed**
  — by apply time the target has passed and you get *no* snooze, rather than rolling to the next
  midnight and handing out a ~24h stand-down (the CLI warns you when you're inside that window).
- `--status` / `--abort` (before it kicks in; once the snooze is live, cancel it with
  `sudo demonlock arm`). Shows in `demonlock status` + the panel; an alert fires when it activates.

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

Override with `CODESIGN_IDENTITY="…"`. (demonlock also keeps a committed Developer-ID `dist/` bundle
it deploys when you have no cert — so it's never downgraded.)

## Uninstall

```bash
sudo ./uninstall.sh            # bootout both, remove app/CLI/plists/sudoers/socket (keeps config)
sudo ./uninstall.sh --purge    # also wipe /Library/Application Support/Demonlock
```
