# Demonlock model — design of record

This is the authority. If the code disagrees with this doc, the code is wrong (or this doc is — fix
whichever is behind). Background facts about macOS location (no GPS on Macs, no poll API, cached
re-delivery, stationary silence, scan throttling) live in the memory note `corelocation-macos-contract`.

## The one principle

> **Every tick the enforcer answers ONE question: is the user PROVABLY in policy right now?**
> **Confident YES → allow. Anything else — out of policy, or can't tell → fail closed: a 10 s
> countdown, then LOCKED.**

There are **no open-ended reprieves**. The "graces" below are not exceptions to fail-closed; they are
just the *bounded windows in which we still have confidence*, and every one of them expires into
fail-closed. There is no `INITIALIZING` phase and no startup grace — the 10 s countdown is the only
buffer, and it cancels the instant a tick proves you're in policy.

## Two processes

**The agent** (user, foreground `.regular`, dock icon — macOS only gives a foreground app live Wi-Fi
scans). Pure sensor pipe: streams genuine CoreLocation fixes (only those measured after launch/wake,
never Apple's cached re-delivery), reports a rolling Wi-Fi BSSID log, and reports the PIDs of the user's
GUI apps (the lockout kill-list, **excluding itself**). Heartbeats a FeedPayload ~1/s over a cdhash-pinned
Unix socket. Holds no truth and makes no decisions — a user can kill it (feed goes stale ⇒ fail-closed)
but can't make it lie (signed binary; socket peer verified against our own cdhash).

**The enforcer** (root, sole judge + sole state-holder). Holds the one location truth in root-owned
`heldfix.json`, evaluates the policy, runs the countdown, performs the lockout, keeps Wi-Fi on, publishes
`state.json`. Ticks ~1 s (time is an input: countdown, `TIME_IS_ANY`, snooze, console user, agent liveness).

## Location confidence — ONE timer

The held fix is the one location truth: `HeldFix{lat, lon, fixTs, acc, anchor, confirmedUntil}`, persisted
root-owned so login/reboot need nothing special and the user can't forge it. It carries a single timer:

> **The held fix is LIVE (usable by the policy) iff `now < confirmedUntil`. Only a LIVE fix feeds the
> policy; STALE or missing ⇒ location unknown ⇒ fail-closed.**

Every **confirmation** pushes `confirmedUntil = now + graceSeconds`:
- a **new fix** adopted (strictly newer `fixTs` — the anti-resurrection gate; a re-streamed stale fix
  can't masquerade as new), capturing the stable BSSIDs visible now as its (frozen) anchor; **or**
- the live Wi-Fi scan still **overlaps** the anchor (≥1 shared stable BSSID).

Anything that is **not** a confirmation simply stops pushing, so the timer runs out → STALE → fail-closed.
One timer; every "no signal" case coasts identically:

| Situation | Confirms? | Result |
|---|---|---|
| At home, agent alive — anchor overlaps each tick | yes | timer keeps pushing → **LIVE → allow** (never expires while confirmed) |
| Wi-Fi off / left RF range (agent alive, no/foreign scan) | no | coast `graceSeconds`, then **STALE → fail-closed** |
| **Agent dead / killed** (no feed for `feedFreshSeconds`) | no (not even processed) | coast `graceSeconds`, then **STALE → fail-closed** |
| Moving vehicle in a big zone | each new fix re-pushes | LIVE while fixes keep landing |
| Adopted a fix with no scan (empty anchor) | the fix confirmed it | LIVE for `graceSeconds`; re-confirmable only by a NEW fix (an empty anchor is never grown/backfilled — that would pin old coords to a new place's APs) |

`confirmedUntil` is persisted on every material change (coords/anchor) **and** as a heartbeat at least
every `heldPersistSeconds`, so an enforcer restart reads a still-LIVE timer instead of a stale one (else
you'd be falsely locked on restart while sitting still — a bug the review caught).

### The BSSID anchor + overlap (band-steering)

The anchor is the set of **stable BSSIDs** (universally-administered MACs — `isStableBSSID`; randomized/
virtual MACs filtered out) seen when the fix was adopted. Overlap = **≥1** shared (not ≥2: macOS hands a
background agent sparse scans, so demanding two false-locks you at home). We check **BSSIDs, never SSIDs**
(a network name is shared across thousands of routers; each router's BSSID is unique).

The anchor is a **frozen, rich snapshot**: the agent feeds the **union of BSSIDs seen in the last
`scanWindowSeconds`** (a rolling log that ages out, NOT cleared on Wi-Fi off), and a full `scanForNetworks`
returns **both radios of a dual-band router at once** (`…:f9` 2.4 GHz + `…:fa` 5 GHz). So both the anchor
and every live overlap check hold both bands → **band-steering between radios never drops overlap to zero**
(the at-home false-lockout that started all this). An **empty** rolling window (no BSSID at all for the
whole window) is positive signal-loss — the unthrottled associated-AP read yields ≥1 BSSID whenever you're
joined, so "nothing" means Wi-Fi is genuinely gone → it stops confirming → fail-closed.

## The phase machine

Phases: **STANDBY · MONITORING · COUNTDOWN · LOCKED · SNOOZED**.

```
console user ≠ enforced user / nobody logged in ─► STANDBY    (no enforcement)
snooze active ────────────────────────────────► SNOOZED    (allow)

evaluate policy on the LIVE held fix (nil if STALE/absent):
   policy == true  ─────────────────────────────► MONITORING (allow); clear countdown
   policy == false / unknown ───────────────────► COUNTDOWN  (countdownSeconds, re-evaluated every tick)
        │  back in policy at any tick ──────────► cancels instantly → MONITORING
        ▼
   countdown elapsed, still not in policy ──────► LOCKED      (force-kill GUI; below)
        │  back in policy at any tick ──────────► MONITORING (kills stop immediately)
```

Every arrow re-evaluates every tick. The held-fix evaluation is decoupled from feed freshness: each tick
the fix is `LIVE ? coords : nil`; a fresh feed only refreshes the confidence timer (adopt / confirm).

## The lockout (LOCKED)

Force-kill the user's GUI apps, **sparing the agent** so the sensor survives and recovery is instant:

- **Agent alive:** root `SIGKILL`s every `.regular` GUI app the agent reported — it excludes its own PID
  and the `spareBundleIDs` list (`settings.json`, live-reloaded: persistent utilities — AltTab, Karabiner,
  BetterDisplay, wtalk, demonlock itself — that break when SIGKILLed). Pure daemons aren't `.regular`, so
  they're never in the list. (The spare-list does NOT cover the nuclear path below — that takes down all GUI.)
  Forceful, every tick. Your distracting apps die within ~1 s of opening; the agent keeps reporting, so the
  moment you're back in policy the enforcer stops killing — no fixed re-lock interval needed.
- **Agent dead** (no kill-list): root `killall -9 WindowServer` (nuclear — SIGKILL, *uncatchable*, so the
  GUI actually tears down to the login window; plain `killall`=SIGTERM is ignored by WindowServer and was a
  silent no-op), rate-limited to `nuclearRelockSeconds` so the agent gets a window to relaunch and report.

**Keeping the agent alive (so it rarely comes to the nuclear path):** the agent is exempt from App Nap
(`beginActivity`, so a backgrounded foreground app isn't QoS-throttled), and its Wi-Fi scan loop drains an
`autoreleasepool` every cycle (without it, CoreWLAN's autoreleased objects leak into GBs over days of
uptime → jetsam/throttle → false locks — a real bug this caught). And when the agent goes silent while
armed, the root daemon **`launchctl kickstart -k`s it** (rate-limited `agentKickSeconds`) — KeepAlive only
restarts a *dead* process, so this is what recovers a *wedged-but-alive* (throttled/stuck) agent.

**Startup/recovery grace (`agentGraceSeconds` = 25):** an agent silent for LESS than this is treated as
"starting up / brief blip" — neither the kickstart nor the nuclear `killall -9` fires. So a normal
login/boot/wake gap (where the held fix coasts and the agent re-confirms via a Wi-Fi scan in ~5 s) **never**
nukes your GUI; only a genuinely-gone agent (silent past the grace) does. The gentle selective kill (agent
alive, out of policy) is unaffected — it still fires at the 10 s countdown.

`sshd` / `tmux` / detached daemons survive both → you can SSH in and `sudo demonlock disarm`. The panel and
`status` show an `ssh minh@<ip> · minh@<host>.local` hint (computed root-side) so you know where to connect.

## Lifecycle — what happens, and why it doesn't flap

- **Cold boot, in policy:** `heldfix.json` is loaded; if its `confirmedUntil` expired while powered off
  (you could have moved), the first tick is STALE → COUNTDOWN. The agent comes up (RunAtLoad) and confirms
  via a Wi-Fi anchor scan (~5 s, faster than a fresh fix) → cancels the countdown before it locks. A genuinely
  fresh install with no held fix is the same path (no fix yet → countdown → first fix cancels it).
- **Login after a lockout:** `resetSession` clears only the last feed packet; the held fix persists and is
  judged on its own timer. Out-of-zone last-known → countdown immediately (no per-login reprieve → **no
  oscillation**, the bug that motivated this rewrite). In-zone & still-LIVE → allowed at once.
- **Wake from sleep at home:** the agent (alive through sleep) re-acquires on `didWake`; `confirmedUntil`
  likely expired during the nap → a brief COUNTDOWN that the first anchor scan cancels (~5 s). Woke elsewhere
  → no overlap → countdown completes → LOCKED. (Re-verifying after a nap is correct, not a bug.)
- **Amphetamine / `caffeinate`** (no system sleep): nothing special — the scan loop and feed keep running;
  `confirmedUntil` keeps being pushed while you're home.
- **Enforcer restart** (KeepAlive / config reload): the heartbeat-persisted `confirmedUntil` is still LIVE
  → resumes MONITORING with no countdown.

## Knobs (code defaults; `settings.json` seeds only `enforcedUser`/`wifiDevice`)

- `graceSeconds = 90` — how long the held fix stays LIVE after the last confirmation (a new fix or an
  anchor overlap). The coast for Wi-Fi blips, moving vehicles, brief agent gaps, and a dead agent alike.
- `countdownSeconds = 10` — the one visible buffer before LOCKED, for every block; cancels on recovery.
- `maxAccuracyMeters = 400` — a fuzzier fix isn't adopted. Generous because accuracy only matters vs
  zone size: big zones (a metro) tolerate fuzzy moving-vehicle fixes (Caltrain reports a few hundred m),
  and small zones sit in dense Wi-Fi so they get good accuracy anyway. Lower it if you rely on tight
  zones in sparse areas. Containment is **center-point-in-zone** — the accuracy radius is only this gate.
- `scanSeconds = 6` — full `scanForNetworks` cadence (CoreWLAN floor ~4 s); the agent also re-reads the
  associated AP every ~2 s.
- `scanWindowSeconds = 30` — rolling BSSID-log window; an empty window = signal-loss → stop confirming.
- `heldPersistSeconds = 30` (internal) — heartbeat-persist cadence for `confirmedUntil`.
- `feedFreshSeconds = 5` (internal) — no packet within this ⇒ agent considered dead.
- `nuclearRelockSeconds = 15` (internal) — `killall -9 WindowServer` cadence while the agent is dead.
- `agentKickSeconds = 30` (internal) — how often the daemon force-restarts a wedged-but-alive agent.
- `agentGraceSeconds = 25` (internal) — startup/recovery grace: an agent silent less than this is "starting
  up", so neither the kickstart nor the nuclear `killall -9` fires (a normal login/boot/wake never nukes).

There is **no fix-age knob** and no startup-grace knob — a held fix is valid while it keeps being confirmed,
never judged by raw age.

## Accepted residuals (honest, signed off)

1. **Leaving fully offline** (Wi-Fi off → no scan AND no new fix) stays allowed up to `graceSeconds` +
   countdown ≈ **100 s**, then fail-closes. Online, an out-of-zone fix lands in tens of seconds → countdown.
2. **A newly-opened app survives ~1–2 s** during LOCKED (until it appears in the next agent feed), then is
   SIGKILLed. Not enough to be usable; relaunching just kills it again.
3. **`.accessory` / LSUIElement apps aren't in the kill-list** (only `.regular` apps are) — a deliberately
   repackaged menubar app could dodge the lockout. Real distractions (browsers, games, video) are `.regular`.
   Honor-system residual, like SSID/BSSID self-naming.
4. **Killing the agent** → the daemon `kickstart -k`s it (recovers a wedged one) and, if still silent,
   `killall -9 WindowServer` every `nuclearRelockSeconds` (SIGKILL drops you to the login screen → STANDBY,
   so the window between kills isn't usable GUI). Bounded, not zero.
5. **A mobile AP that travels with you** (a carried hotspot mirroring an anchor BSSID; a train's own router)
   keeps the anchor "matching" → corrected by the next CoreLocation fix (online), per the Caltrain analysis.
6. **Rural stale-single-AP fix** with deceptively good accuracy could briefly mislocate you — defended by
   `maxAccuracyMeters`.
7. **Physical RF spoofing of home BSSIDs** (evil twin) — exotic, accepted.
8. **Software location spoofing / disarm** require sudo/admin (SIP, hardened runtime, root-only files) —
   blocked by the no-admin posture; an admin *you* can always disarm (by design — that's the held password).

The BSSID anchor is the liveness backbone while you're joined to Wi-Fi (the unthrottled associated AP keeps
it fed); CoreLocation fixes are the position truth. Together: confirmed → allow; unconfirmed → fail-closed.
