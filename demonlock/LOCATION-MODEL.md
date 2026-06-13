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
Apple's documented cached re-delivery and clock-skew wedges). Scans BSSIDs EAGERLY from two LIVE
sources, never the OS cache: (1) the AP it's **associated** with (`iface.bssid()`) — re-read every
~2s, no scan/throttle, so the band you're on *right now* is always current; (2) a full
`scanForNetworks` every `scanSeconds` — richer (ALL bands of ALL nearby APs at once), but macOS
throttles it for a background app (the reason for `.regular`). The fed "current BSSIDs" = the **union
of everything seen in the last `scanWindowSeconds`** — a rolling log that ages out and is NOT cleared
on Wi-Fi off; an **empty** union (nothing for the whole window) is reported as no-scan = signal-loss.
Heartbeats a FeedPayload ~1/s. It holds nothing as truth and makes no decisions — a user can kill it
(feed goes stale ⇒ fail-closed) but can't make it lie (cdhash-pinned socket, signed binary).

**The enforcer (root, sole judge + sole state-holder).** Holds the one truth in root-owned
`heldfix.json` (`HeldFix{lat,lon,fixTs,acc,anchor,graceUntil?}`), persisted so login/reboot
need nothing special and the user can't forge it. Per tick the pure `judgeLocation()`:

1. **Adopt** any STRICTLY-newer valid fix (`ts > held.fixTs`; finite coords; `0 ≤ acc ≤ maxAccuracyMeters`),
   capturing the stable BSSIDs visible now as its anchor (or `[]` if no scan). A new fix REPLACES the
   record outright (fresh coords, fresh anchor snapshot, grace cleared). The anchor is then **frozen** —
   never grown afterward (growing it post-adoption let an offline move poison it with a new place's APs).
   It is still RICH because the agent feeds the union of BSSIDs seen in the last `scanWindowSeconds`, and a
   full sweep returns ALL radios of ALL nearby APs at once — so both BSSIDs of a dual-band router land in
   the snapshot. The strict `>` is the anti-resurrection gate — a grace-expired fix keeps its `fixTs` as a
   high-water tombstone, so the agent re-streaming it can't revive it; only a genuinely new measurement can.
2. **Trust the held fix unless evidence of leaving — OR loss of signal.** With a non-empty anchor, the
   rolling-window scan must VOUCH for it (≥1 overlap). It fails to vouch if it shows only foreign APs
   (you moved) **or** is empty (no Wi-Fi at all for the whole window — off / unjoined / left RF range).
   EITHER ⇒ start `graceSeconds` (persisted, not reset on reboot); a vouching scan or a fresh fix clears
   it; expiry ⇒ untrusted (fail-closed), record KEPT as the high-water tombstone. The empty window is
   treated as signal-loss, **not** "can't tell", because the unthrottled associated-AP read logs ≥1 BSSID
   whenever you're joined — so "nothing for `scanWindowSeconds`" is genuine loss, and trusting through it
   was the Wi-Fi-off bypass. Only an **empty anchor** (a fix adopted with no scan at all — rare, since a
   Mac fix needs Wi-Fi) still degrades to **TRUST**, and is never backfilled.
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

**Dual-band / band-steering** is handled by feeding RICH scans on both ends of the check. A router
exposes a separate BSSID per radio (`…:f9` on 2.4 GHz, `…:fa` on 5 GHz); the original lockout happened
because the agent fed only one instantaneous BSSID, so the anchor was `{…:fa}` while the Mac had steered
onto `…:f9` → zero overlap → false "moved". The fix: the agent feeds `associated AP ∪ most-recent full
sweep`, and a full sweep returns **both** radios at once. So **both** the frozen anchor snapshot **and**
every live overlap check include both bands → steering between radios can never drop overlap to zero.
This needs a full sweep to have landed recently (≤ the agent's sweep-cache window, ~12s); with sweeps
running every `scanSeconds` that's effectively always, and if a sweep drought ever does coincide with a
steer, the worst case is a transient `graceSeconds` coast that the next sweep or fix clears — never a lock
in practice, and never a fail-open.

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

1. **Leaving an allowed place fully offline** (Wi-Fi off, so no scan AND no new fix) stays allowed only
   up to the rolling window `scanWindowSeconds` (the just-left APs aging out) + `graceSeconds` + countdown
   ≈ **130s**, then **fail-closes** — it no longer trusts indefinitely (that was the Wi-Fi-off bypass).
   Online, an out-of-zone fix lands in tens of seconds → countdown.
2. **`scanForNetworks` throttling is tolerated by the associated-AP floor:** while joined to Wi-Fi, the
   unthrottled `iface.bssid()` read logs ≥1 BSSID every ~2s, so the rolling window is never empty from
   throttling alone — only from genuine signal-loss (Wi-Fi off / unjoined / out of range), which is the
   intended fail-closed trigger. On Ethernet-only with Wi-Fi off, the window empties ⇒ fail-closed (a
   Wi-Fi locker needs Wi-Fi); when armed, `wifiKeepOn` forces the radio back on.
3. **Within one router's coverage** (~100m) you aren't flagged as moved — small area.
4. **Rural stale-single-AP fix with deceptively good accuracy** could briefly mislocate you.
5. **A mobile AP that travels with you** (a phone hotspot you carry; a train's own router) keeps the
   anchor "matching" → corrected by the next CoreLocation fix (online), per the Caltrain analysis.
6. **Physical RF spoofing of home BSSIDs** (evil twin) — exotic, accepted.

## Knobs (code defaults; `settings.json` seeds only `enforcedUser`/`wifiDevice`)

- `graceSeconds = 90` — coast after a positive "moved" before fail-close; the offline-leave bound.
- `maxAccuracyMeters = 150` — fix quality gate + the rural wrong-fix defense.
- `scanSeconds = 6` — full `scanForNetworks` (all-bands) cadence (CoreWLAN floor ~4s). The agent ALSO
  re-reads the associated AP every ~2s, so the live band is current between sweeps. A full sweep grabs
  both radios of a dual-band router at once → rich anchor snapshot + rich live check (band-steering fix).
- `scanWindowSeconds = 30` — rolling-log window: the agent reports the union of BSSIDs seen in this span
  (ages out, not cleared on Wi-Fi off). An empty window = positive signal-loss → grace → fail-closed.
- `initMaxSeconds = 30` — startup grace (agent coming up OR no held fix yet).
- `staleSeconds = 30` — TRANSPORT staleness (is the agent alive?). There is **no fix-age knob**.

The anchor is the **liveness backbone now**: while joined, the unthrottled associated AP keeps it fed, so
a sustained empty scan means you genuinely lost Wi-Fi → fail-closed (only an empty-at-adoption anchor, or
an out-of-zone CoreLocation fix, falls back to fix-only judgement).
