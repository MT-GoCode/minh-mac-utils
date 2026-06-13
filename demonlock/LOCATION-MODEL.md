# Demonlock location model — design of record

This is the authority; if code disagrees with this doc, the code is wrong.
Background facts (no GPS on Macs, no poll API, cached re-delivery, stationary silence)
live in the memory note `corelocation-macos-contract`.

> **Note:** the block below is the original informal spec, kept for history. The CURRENT
> authoritative behavior is **"How it works"** below it; where they differ, the code + that
> section win. Three material differences from the literal spec: (a) adoption is strictly-
> newer-fixTs (a high-water mark), not "did a fix arrive this tick"; (b) a stale/MISSING scan
> does NOT fail-close — it TRUSTS the held fix (graceful degradation), because macOS won't
> reliably let a background agent scan, so the "no scan → killed" edge cases below are now
> "no scan → trusted"; (c) overlap needs only ONE shared BSSID, not two. Do not revert toward
> the literal wording; the `judgeLocation` tests guard it.

## The spec (near-verbatim, 2026-06-12)

> **watcher:**
> any Fix comes → evaluate as per normal for the next tick, including logging APs.
> small, atomic, constrained state change, single file. get another fix, clear this fix data.
>
> **Every tick,**
> - fix came within last tick — evaluate as per normal. delete any GRACE-PERIOD-LOCATION if so.
> - fix did not come within last tick + last fix exists — check BSSIDs overlap since the last
>   fix's data. if yes → evaluate old fix as per normal + clear GRACE-PERIOD-LOCATION.
>   if no → set GRACE-PERIOD-LOCATION state with a 90s deadline for a fix before reporting
>   fail-close. if no + GRACE-PERIOD-LOCATION already set and past deadline → kill the fix
>   data. report this in UI. next case will likely pinball into this.
> - fix did not come within last tick + no last fix exists — fail-close.
>
> **"Evaluate as per normal"**
> - check the fix's membership within every single zone on the map.
> - return that for checking the conditions.
>
> **When login/startup** — do nothing different. don't have to clear a fix.
>
> **Edge cases:**
> - a place with wifi so stable corelocation gives no fixes — inherently covered by AP check.
> - in a good zone, turn off wifi, walk out — can't get fix, can't get APs either, killed.
> - in a good zone, wifi on (maybe hotspot), walk out — fix → out of zone, killed;
>   no fix → APs don't overlap, killed.
> - moving vehicle, in zone — must get fixes within the 90s grace deadlines (grace needed
>   because APs keep switching). out of zone with fixes → killed. out of zone, no fixes →
>   the grace kills you too.
> - if stable BSSIDs on a caltrain trick the system into thinking I was stable, we will
>   attain a new fix from corelocation anyway and re-evaluate then. otherwise we'd have to
>   be entirely offline. *(confirmed by research — see below)*

## How it works (current — authoritative)

**The watcher (agent, foreground `.regular` so macOS lets it scan; shows a dock icon).** Streams
genuine CoreLocation fixes — only those measured after launch/wake and not future-stamped (rejects
Apple's documented cached re-delivery and clock-skew wedges). Scans BSSIDs from two LIVE sources,
never the OS cache: (1) the AP it's **associated** with (`iface.bssid()`) — available in the
background with no scan/throttle, the dependable anchor when joined to Wi-Fi; (2) a full
`scanForNetworks` — richer, but macOS throttles it for a background app (the reason for `.regular`).
Heartbeats a FeedPayload ~1/s. It holds nothing as truth and makes no decisions — a user can kill it
(feed goes stale ⇒ fail-closed) but can't make it lie (cdhash-pinned socket, signed binary).

**The enforcer (root, sole judge + sole state-holder).** Holds the one truth in root-owned
`heldfix.json` (`HeldFix{lat,lon,fixTs,acc,anchor,graceUntil?}`), persisted so login/reboot need
nothing special and the user can't forge it. Per tick the pure `judgeLocation()`:

1. **Adopt** any STRICTLY-newer valid fix (`ts > held.fixTs`; finite coords; `0 ≤ acc ≤ maxAccuracyMeters`),
   capturing the stable BSSIDs visible now as its anchor (or `[]` if no scan). The strict `>` is the
   anti-resurrection gate — a grace-expired fix keeps its `fixTs` as a high-water tombstone, so the
   agent re-streaming it can't revive it; only a genuinely new measurement can.
2. **Trust the held fix unless POSITIVE evidence of leaving.** "Moved" = a FRESH scan exists **and**
   the anchor is non-empty **and** *no* anchor BSSID is in the current scan. On "moved", start
   `graceSeconds` (persisted in the fix, not reset on reboot); a fresh fix at any point clears it.
   Grace expired ⇒ the fix is untrusted (fail-closed) but KEPT as the high-water tombstone. A
   stale/missing scan, or an empty anchor, can't prove you left ⇒ **TRUST** (graceful degradation):
   requiring a scan would fail-close you at home whenever macOS throttles it (the bug that proved it).
3. **Evaluate** the (lat,lon) against every zone → feed the three-valued policy.

The enforcer ticks ~1s for the clock-driven inputs (countdown, `TIME_IS_ANY`, snooze, console, dead
agent). Startup INITIALIZING grace (no countdown) holds while the agent isn't reporting yet **or** no
held fix exists yet, bounded by `initMaxSeconds`. At countdown zero, armed ⇒ `launchctl bootout`.
Other invariants: grace lives inside the persisted fix; the state machine is pure and unit-tested per
transition; session change clears the feed (`server.clear()`) so a fast relogin can't inherit a dead
packet; behavior knobs are owned by code defaults (installer seeds only `enforcedUser`/`wifiDevice`).

### The BSSID overlap check, precisely

The anchor is the set of **stable BSSIDs** — per-physical-AP hardware MACs, universally-administered
(`isStableBSSID`; randomized/virtual MACs are filtered out) — visible when the fix was adopted. Each
tick: **"still here" iff ANY anchor BSSID is still in the current scan** (`≥1`, in `bssidOverlapOK`).
We check **BSSIDs, never SSIDs**: the network *name* (e.g. "SF Free WiFi") is shared across thousands
of physical routers, but each router's BSSID is unique — so moving from one physical AP to another,
**even on the same SSID**, drops the overlap to zero → "moved". `≥1` (not `≥2`) because macOS hands a
background agent sparse, inconsistent scans (often just the associated AP); demanding two falsely reads
"moved" when only 1 of your N APs came back this scan (the false-lockout-at-home bug). Detection fires
once you leave the ~range (~100m) of *all* anchor APs; inside a big zone the next CoreLocation fix just
re-anchors you, so you stay allowed while routers/roaming change (online).

### No requirement, no backfill (both were fail-modes)

- **A fresh fix is authoritative on its own** — adopted/trusted with or without a scan.
- **An empty anchor is NOT backfilled** from a later scan: after an offline move that would anchor the
  OLD coordinates to the NEW place's APs and "confirm" there forever (fail-open). It stays empty
  (trusted via degradation) until a genuinely new fix re-anchors.

## Research-confirmed (2026-06; sources in memory)

- **Moving vehicle with internet keeps getting real fixes** tracking position (seconds to
  tens of seconds; each Apple WPS lookup also resolves ~hundreds of nearby passing APs).
  "Trust until the next fix" self-corrects travelling-AP trickery. *[high]*
- Apple **excludes phone/Mac hotspots** from its positioning DB, but NOT dedicated vehicle
  routers; on populated routes the fixed trackside APs outvote the onboard one. *[med-high]*
- **Rural, only the onboard router resolvable:** usually NO fix (safe — grace governs);
  occasionally a confidently-wrong stale fix anchored to the router's old DB location —
  defended by the `maxAccuracyMeters` gate (single-AP fixes usually report poor accuracy),
  which is therefore load-bearing, not cosmetic. *[medium]*

## Accepted residuals (honest, signed off)

1. **Leaving an allowed place fully offline** stays allowed up to `graceSeconds` (+countdown ≈ 100s)
   — and only once a FRESH scan positively shows you left; a missing scan trusts the held fix
   indefinitely (degradation). Online, an out-of-zone fix lands in tens of seconds → countdown.
2. **Background scan is unreliable** (macOS 26 throttles `scanForNetworks` even for a foreground-ish
   app). The **associated-AP BSSID** is the dependable anchor, so leave-detection is strongest when
   you're joined to Wi-Fi. On Ethernet with no association and a throttled scan, the anchor is often
   absent ⇒ location runs on CoreLocation fixes + held-fix alone (the anchor is a bonus, not a backbone).
3. **Within one router's coverage** (~100m) you aren't flagged as moved — small area.
4. **Rural stale-single-AP fix with deceptively good accuracy** could briefly mislocate you.
5. **A mobile AP that travels with you** (a phone hotspot you carry; a train's own router) keeps the
   anchor "matching" → corrected by the next CoreLocation fix (online), per the Caltrain analysis.
6. **Physical RF spoofing of home BSSIDs** (evil twin) — exotic, accepted.

## Knobs (code defaults; `settings.json` seeds only `enforcedUser`/`wifiDevice`)

- `graceSeconds = 90` — coast after a positive "moved" before fail-close; the offline-leave bound.
- `maxAccuracyMeters = 150` — fix quality gate + the rural wrong-fix defense.
- `scanSeconds = 10` — BSSID rescan cadence (CoreWLAN rate-limits ~4s; don't hammer).
- `initMaxSeconds = 30` — startup grace (agent coming up OR no held fix yet).
- `staleSeconds = 30` — TRANSPORT staleness (is the agent alive?). There is **no fix-age knob**.

The anchor is a **bonus, not a backbone**: location works on CoreLocation fixes alone (degradation),
and the BSSID anchor tightens "did I leave" whenever a live scan / associated AP is available.
