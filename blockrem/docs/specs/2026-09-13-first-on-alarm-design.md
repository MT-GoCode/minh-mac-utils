# blockrem: "first-on" conditional alarms

**Date:** 2026-09-13 · **Status:** FINAL (as built 2026-09-14) — adversarial + confirm + implementation-review passes folded (13 + 3 + 3 findings); 78/78 `_selftest` green

## What

A third alarm kind, alongside `--weekly` and `--onetime`: a **first-on** alarm fires **once per
listed day**, at the **first instant inside a time window** (e.g. 05:00–09:00) that the machine is
actually **in use** — awake, display on, the enforced user at the console, and the screen
unlocked. The block itself is completely standard: same grey cover, countdown, mute, input tap,
same `--duration` (5–3600 s). Nothing about rendering or enforcement changes.

```sh
blockrem set --first-on "*0500-0900"  --label "morning pages" --duration 300
blockrem set --first-on "MTWRF0700-1000" --label "no email before plan" --duration 60
```

## Semantics (decided with user)

- **Trigger = first use, not first awake.** A machine sitting awake-but-locked (or at the login
  screen, or dark-woken with the display off) does not fire at 05:00; the alarm waits for the
  first real use inside the window.
- **Already in use at window start → fires at window start** (you're at the keyboard at 04:50, the
  05:00–09:00 alarm fires at 05:00:00 sharp).
- **Never in use during the window → skipped that day.** No catch-up firing at 09:01.
- **Once per local day**, resetting at midnight. Days-of-week selectable with the existing
  `M T W R F S U | *` letters.
- **Snooze gates the trigger.** While snoozed the alarm cannot fire; if the snooze clears while
  still inside the window (and it hasn't fired today), it fires then; snoozed past the window
  end → skipped that day. Note this is *deferred-fire* — a genuinely new interaction: for
  weekly/onetime alarms snooze suppresses a block whose time simply passes, whereas here the
  trigger itself waits. This behavior depends on ordering and is pinned below.
- **No new audio/visual behavior.** "Ring" = the standard block firing. (User: "reuse the code!")

### One deliberate deviation from the Q&A

The chosen option said "falls back to 'awake' if lock state is unavailable." Spec'd stricter:
**unknown state = not in use** (the trigger waits, and lock state seeds as *locked* until proven
otherwise). Reason: use-state comes from the GUI agent's heartbeat (below), and if the agent isn't
running there is *nothing to render the block anyway* — firing would burn the once-per-day shot
invisibly. The agent is KeepAlive'd **and** revived by the daemon's 5 s watchdog, so a missing
heartbeat is a short transient (watchdog 5 s + startup write; launchd throttling can stretch a
crash-loop, but then no fire is correct — nothing could render it). Worst case the alarm fires a
minute late inside a multi-hour window. Same fail-direction as the rest of blockrem: **never fire
where you can't see it.**

## Design

### Data model (`Schedule.swift`)

```swift
enum Kind: Codable {
    case weekly(days: [Int], hhmm: Int)
    case onetime(start: Double)
    case firstOn(days: [Int], startHHMM: Int, endHHMM: Int)   // NEW — window [start, end), local
}
var lastFiredEpoch: Double?    // NEW field on Alarm; only meaningful for .firstOn
```

`lastFiredEpoch` does double duty:

- **fired-today check:** `Calendar.current.isDate(firedDate, inSameDayAs: now)`
- **active-block window:** `activeEnd(now:)` for `.firstOn` returns
  `lastFiredEpoch + duration` when `now ∈ [lastFiredEpoch, lastFiredEpoch + duration)`, else nil.

**The latch is memory-authoritative** (adversarial finding #1 — BLOCKER): the Enforcer keeps an
in-memory `fired: [alarmID: Double]` map, set at trigger time, and **merges it over whatever it
reloads from disk every tick** (`fired[id]` wins over a nil/older `lastFiredEpoch`). The disk copy
in `schedule.json` exists only so a daemon restart mid-block resumes the block and keeps the
daily latch. Without this, a silently failed `ScheduleStore.save` (it `try?`s everything) would
make the next tick's reload see an unlatched alarm and refire *every second* — a rolling
unquittable block that could outlive the 1-hour cap for the whole window. **The merge is
two-way** (confirm-pass N1: a one-way memory→disk merge would leave `fired` empty after a
daemon restart and double-fire mid-day): each tick,
`merged[id] = max(fired[id] ?? 0, disk lastFiredEpoch ?? 0)`, the guard reads `merged`, and
`fired` is updated to it. The same merge closes the CLI lost-update race (finding #8): a
`set`/`delete` that loaded pre-latch and clobbered `lastFiredEpoch` on disk cannot cause a
refire, because memory still holds the latch; the daemon re-persists it on its next write.
`delete` of a fired alarm also drops its `fired` entry (daemon prunes entries whose id no
longer exists in the loaded schedule). Known accepted race (N2): delete the highest-id fired
alarm and re-`set` within the same 1 s tick and the new alarm inherits the reused id's latch —
consequence is one day's suppression, window ≤ 1 s, not worth machinery.
<!-- ponytail: id-reuse latch transfer accepted; make nextID monotonic if it ever bites -->

**Codable/migration:** the new enum case and the optional field are purely additive — Swift
synthesizes nested-key coding for `Kind` (`{"weekly":{…}}`), so old files decode under the new
binary, and `lastFiredEpoch` decodes via `decodeIfPresent`. (Old binaries can't decode a file
containing a `firstOn` alarm — irrelevant: binary and schedule upgrade together.)

### In-use detection

`inUse(now)` = all of:

1. **Console + awake** — already exists: the daemon only proceeds when
   `consoleUID() == settings.enforcedUID()`. This excludes the login screen and other users.
2. **Session heartbeat fresh, unlocked, display on** — the **agent** (already ticking every
   0.25 s) writes:

```
data/session.json     owner: enforced user (dataDir already is)
{ "updatedEpoch": …, "locked": false, "displayAsleep": false }
```

The agent **polls** the state — it does not trust lock/unlock events (finding #4: the
`com.apple.screenIsLocked` distributed notifications are undocumented, best-effort, and known to
miss transitions around fast-user-switch, display-sleep grace periods, and session churn; one
missed event would poison the whole day in either fail direction). Poll =
`CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` (absent key ⇒ unlocked;
**inconclusive/nil dictionary ⇒ locked** — finding #3) plus
`CGDisplayIsAsleep(CGMainDisplayID())` (finding #5: dark wake / Power Nap runs user-space with
the display off — the daemon *does* tick then, so "asleep machines don't tick" alone is not a
gate). Poll every 5 s inside the existing agent timer; write `session.json` **once at startup**
(finding #9), on any state change, and every 30 s as heartbeat. No observers at all — the poll
replaces them (simpler and reconciling by construction).

**Daemon side:** heartbeat fresh (`now − updatedEpoch ≤ 90 s`) ∧ `!locked` ∧ `!displayAsleep`.
Stale or missing → **not in use** (see deviation above).

Spoofing note: `session.json` is user-owned, so the user could fake "locked" to suppress firing —
equivalent power to the existing no-sudo `snooze`, so no new trust boundary.

### Daemon trigger (`Enforcerd.tick`)

**Placement is load-bearing (finding #7): the trigger runs *after* the snooze early-return**
(`Enforcerd.swift:47`) and before `activeBlock()`. Put it before the snooze block and snooze
would no longer gate the latch — the deferred-fire semantics above would silently break.

```
// after console guard, after snooze early-return:
fired[id] = max(fired[id] ?? 0, loaded lastFiredEpoch ?? 0)   // two-way merge (N1)
prune fired ids not in schedule
for each .firstOn alarm a:
    guard today's weekday ∈ a.days
    guard nowHHMM ∈ [a.startHHMM, a.endHHMM)
    guard fired[a.id] is nil-or-not-today
    guard inUse(now)
    → fired[a.id] = now; write through to schedule.json; log "first-on [id] fired"
```

Then the existing `activeBlock()` path picks it up via the new `activeEnd` case — zero changes to
publishing, rendering, mute, or the tap.

The daemon's schedule write leaves the file root-owned in the user dataDir (finding #12) —
atomic-replace CLI writes still work (they need only directory write, and pruning already does
this today), but the daemon should `chown` back to the enforced user after write to keep the
documented ownership story true.

Clock edge: a backwards clock jump across midnight can make the same-day check read false and
refire once. Accepted — bounded to one extra block, DST-rare.

### CLI (`Commands.swift`, `TimeSpec.swift`)

- `blockrem set --first-on "<DAYS|*><HHMM>-<HHMM>" --label "…" --duration <5-3600>`
  New `TimeSpec.parseFirstOn`: split on the `-` between the two HHMMs, reuse the day-letter
  parsing from `parseWeekly`, both times `validHHMM`, **start < end** (same-day window).
  Cross-midnight windows (`2200-0600`) are refused with a clear message.
  <!-- ponytail: no cross-midnight windows; add a second wrapped segment in parse + trigger + overlap if ever wanted -->
- `list` shows: `first-on \(letters) 5:00 AM–9:00 AM` plus `· fired today 7:23 AM` when latched,
  and the standard `🟥 BLOCKING NOW` line while its block runs.
- `delete`, `snooze`, `help`, README: routine updates. Help text carries the overlap warning
  below.

### Overlap check (`alarmsOverlap`)

A first-on alarm can fire anywhere in its window, so for overlap purposes it **occupies
`[start, end + duration)` on each of its days** — conservative but predictable. Consequence
worth stating out loud (finding #11): a `*0500-0900` first-on is mutually exclusive with *any*
alarm scheduled inside 05:00–09:05 on those days — e.g. the README's `--weekly *0800 water break`
would be refused. That's the decided conservative rule; the `set` error message should name the
window so the user understands why.

Implementation: **restructure `alarmsOverlap` into an exhaustive `switch (a.kind, b.kind)` with
no `default` branch** (finding #6 — today's `default:` would silently return `false` for any
forgotten `firstOn×…` pairing; exhaustiveness makes the compiler catch this and every future
kind). Pairings: firstOn×firstOn and firstOn×weekly via the existing `weekSegments` machinery
with the occupied span; firstOn×onetime by testing the window interval on the days the onetime
touches (mirror of today's weekly×onetime branch).

## Not doing (YAGNI)

- No cross-midnight windows (refused at parse; ceiling noted above).
- No "fire on the Nth use" / re-fire after long idle — one latch per day.
- No per-alarm sound, no notification, no separate binary/daemon — pure reuse.
- No clamping the block to the window end — a 08:59 trigger runs its full duration, consistent
  with weekly blocks.
- No lock/unlock notification observers — the 5 s poll is the whole mechanism.

## Tests (`SelfTest.swift`, extends `blockrem _selftest`)

The trigger is implemented as pure helpers so it's testable (finding #10): the two-way merge is
its own function `mergeFirstOnLatches(fired:alarms:) → (fired, alarms, mutated)` (implementation
review: the load-bearing merge needs direct coverage, not inline daemon code), and
`firstOnShouldFire(alarm, now, inUse: Bool, snoozedUntil: Double?)` reads the merged latch off
the alarm — `tick` passes the real snooze; the early-return ordering is still asserted by test
2.5 exercising the helper's snooze parameter. **`inUse` is itself a pure function** of
`(sessionSnapshot: SessionState?, now)` implementing the freshness ∧ !locked ∧ !displayAsleep
conjunction, tested separately (confirm-pass N3 — otherwise "stale heartbeat → no fire" would
just pass a Bool and test nothing):
- fresh + unlocked + display on → true · stale (> 90 s) → false · missing file → false ·
  locked → false · displayAsleep → false

1. `parseFirstOn`: `*0500-0900`, `MWF0700-1000`, rejects `0900-0500`, `*05000900`, `X0500-0900`,
   `*2430-2500`.
2. Trigger helper:
   - in use at window start → fires exactly at start
   - unlock at 07:23 → fires at 07:23; second check same day → no re-fire
   - locked (or display asleep) whole window → never fires; next day resets
   - stale heartbeat → no fire; fresh unlocked heartbeat → fires
   - `snoozedUntil` 07:00, in use from 06:00 → no fire before 07:00, fires at 07:00
   - **memory-vs-disk (via `mergeFirstOnLatches`):** memory latched + disk nil (failed save /
     CLI clobber) → latch restored, no refire · memory empty + disk latched (daemon restart) →
     fired map reseeded, no double-fire · newer memory wins over older disk · deleted ids dropped
3. `activeEnd` for `.firstOn`: inside/outside the fired window; daemon-restart resume (latch
   persisted, now mid-window → block active).
4. Overlap (occupied span `[05:00, 09:05)` for `*0500-0900` dur 300):
   weekly `*0830` → clash · weekly `*0904` → clash · weekly `*0906` (any dur) → **ok** ·
   weekly `*0910` → **ok** · weekly `*0456` dur 300 → clash (runs into 05:00) · onetime inside /
   outside the span · firstOn×firstOn overlapping / disjoint windows.
5. Codable round-trip: old-format schedule decodes; new alarm round-trips with latch.

(Finding #2 — the v1 expectations for `*0906`/`*0910` contradicted the occupied-span definition;
corrected above.)

## Files touched

`Schedule.swift` (kind, latch, activeEnd, exhaustive overlap) · `Enforcerd.swift` (trigger,
fired map, inUse, chown-after-write) · `State.swift` (SessionStore) · `Agent.swift` (session
poll + heartbeat) · `Commands.swift` + `TimeSpec.swift` (parse, set, list, help) ·
`SelfTest.swift` · `README.md`. No installer, plist, or permission changes. Install rides the
same gate-window sudo session as the demonlock reinstall (`sudo ./install.sh` re-deploys both
services).
