# blockrem: "first-on" conditional alarms

**Date:** 2026-09-13 · **Status:** draft for review

## What

A third alarm kind, alongside `--weekly` and `--onetime`: a **first-on** alarm fires **once per
listed day**, at the **first instant inside a time window** (e.g. 05:00–09:00) that the machine is
actually **in use** — awake, the enforced user at the console, and the screen unlocked. The block
itself is completely standard: same grey cover, countdown, mute, input tap, same `--duration`
(5–3600 s). Nothing about rendering or enforcement changes.

```sh
blockrem set --first-on "*0500-0900"  --label "morning pages" --duration 300
blockrem set --first-on "MTWRF0700-1000" --label "no email before plan" --duration 60
```

## Semantics (decided with user)

- **Trigger = first use, not first awake.** A machine sitting awake-but-locked (or at the login
  screen) all night does not fire at 05:00; the alarm waits for the first unlock inside the window.
- **Already in use at window start → fires at window start** (you're at the keyboard at 04:50, the
  05:00–09:00 alarm fires at 05:00:00 sharp).
- **Never in use during the window → skipped that day.** No catch-up firing at 09:01.
- **Once per local day**, resetting at midnight. Days-of-week selectable with the existing
  `M T W R F S U | *` letters.
- **Snooze wins**, exactly as for every other block: while snoozed the alarm cannot trigger; if the
  snooze clears while still inside the window (and it hasn't fired today), it fires then. Snoozed
  past the window end → skipped that day.
- **No new audio/visual behavior.** "Ring" = the standard block firing. (User: "reuse the code!")

### One deliberate deviation from the Q&A

The chosen option said "falls back to 'awake' if lock state is unavailable." Spec'd stricter:
**unknown lock state = not in use** (the trigger waits). Reason: lock state comes from the GUI
agent's heartbeat (below), and if the agent isn't running there is *nothing to render the block
anyway* — firing would burn the once-per-day shot invisibly. The agent is KeepAlive'd **and**
revived by the daemon's 5 s watchdog, so "heartbeat missing" is a ≤ 35 s transient, not a mode;
worst case the alarm fires half a minute late inside a multi-hour window. This is the same
fail-direction as the rest of blockrem: never fire where you can't see it.

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

Because it's persisted in `schedule.json`, a daemon restart mid-block resumes the block, and the
once-per-day latch survives restarts — same durability as everything else in the file. It is
user-writable (the whole schedule is), but the user can already `snooze`/`delete` without sudo, so
this adds no new escape.

**Codable/migration:** the new enum case and the optional field are purely additive; existing
`schedule.json` files decode unchanged. (Old binaries can't decode a file containing a `firstOn`
alarm — irrelevant: binary and schedule are upgraded together, and `set --first-on` doesn't exist
before the upgrade.)

### In-use detection

Two facts, two owners:

1. **Console + awake** — already exists: the daemon only proceeds when
   `consoleUID() == settings.enforcedUID()`, and a sleeping machine doesn't tick at all. This alone
   already excludes the login screen and other users.
2. **Screen unlocked** — only the user session can see this. The **agent** (which already ticks
   every 0.25 s) gains two `DistributedNotificationCenter` observers,
   `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` (no permission needed), and writes a
   tiny heartbeat file:

```
data/session.json     owner: enforced user (dataDir already is)
{ "updatedEpoch": …, "locked": false }
```

Written on every lock-state change **and** every 30 s (heartbeat). One new `SessionStore` in
`State.swift` (same shape as `ActiveStore`), written by the agent, read by the daemon.

**Daemon's inUse(now):** heartbeat fresh (`now - updatedEpoch ≤ 90 s`) **and** `locked == false`.
Stale or missing → **false** (see deviation above). After wake the agent's 0.25 s timer refreshes
the file within a tick or two, so post-wake firing lags real unlock by at most a few seconds.

Spoofing note: `session.json` is user-owned, so the user could fake "locked" to suppress firing —
equivalent power to the existing no-sudo `snooze`, so no new trust boundary.

### Daemon trigger (`Enforcerd.tick`)

After the snooze check, before computing the active block:

```
for each .firstOn alarm a:
    guard today's weekday ∈ a.days
    guard nowHHMM ∈ [a.startHHMM, a.endHHMM)         // window check, local time
    guard a.lastFiredEpoch is nil-or-not-today       // once per day
    guard inUse(now)                                  // console guard already passed above
    → a.lastFiredEpoch = now; save schedule; log "first-on [id] fired"
```

Then the existing `activeBlock()` path picks it up via the new `activeEnd` case — zero changes to
publishing, rendering, mute, or the tap. The daemon already writes `schedule.json` (onetime
pruning), so persisting the latch reuses that path.

Clock edge: a backwards clock jump across midnight could make `lastFiredEpoch` "tomorrow"; the
same-day check then reads false and it may fire again. Accepted — DST/clock-set is a once-a-year
oddity and the failure is one extra block.

### CLI (`Commands.swift`, `TimeSpec.swift`)

- `blockrem set --first-on "<DAYS|*><HHMM>-<HHMM>" --label "…" --duration <5-3600>`
  New `TimeSpec.parseFirstOn`: split on the `-` between the two HHMMs, reuse the day-letter parsing
  from `parseWeekly`, both times `validHHMM`, and **require start < end** (same-day window).
  Cross-midnight windows (`2200-0600`) are refused with a clear message.
  <!-- ponytail: no cross-midnight windows; add a second wrapped segment in parse + trigger + overlap if ever wanted -->
- `list` shows: `first-on \(letters) 5:00 AM–9:00 AM` plus `· fired today 7:23 AM` when latched,
  and the standard `🟥 BLOCKING NOW` line while its block runs.
- `delete`, `snooze`, `help`, README: routine updates.

### Overlap check (`alarmsOverlap`)

A first-on alarm can fire anywhere in its window, so for overlap purposes it **occupies
`[start, end + duration)` on each of its days** — conservative but predictable. Implementation
reuses the existing machinery: generate its week segments with that span and intersect, exactly
like `weekly × weekly`; against a `onetime`, test the window interval on the days the onetime
touches (mirror of the existing weekly×onetime branch).

## Not doing (YAGNI)

- No cross-midnight windows (refused at parse; ceiling noted above).
- No "fire on the Nth use" / re-fire after long idle — one latch per day.
- No per-alarm sound, no notification, no separate binary/daemon — pure reuse.
- No clamping the block to the window end — a 08:59 trigger runs its full duration, consistent
  with how weekly blocks already behave.

## Tests (`SelfTest.swift`, extends `blockrem _selftest`)

Pure-logic, injected `now` — same style as the existing self-test:

1. `parseFirstOn`: `*0500-0900`, `MWF0700-1000`, rejects `0900-0500`, `*05000900`, `X0500-0900`,
   `*2430-2500`.
2. Trigger math (a pure helper the daemon calls, so it's testable):
   - in use at window start → fires exactly at start
   - unlock at 07:23 → fires at 07:23; second check same day → no re-fire
   - locked whole window → never fires; next day resets
   - stale heartbeat → no fire; fresh unlocked heartbeat → fires
   - snooze until 07:00 with unlock at 06:00 → fires at 07:00 (via the snooze-gate ordering)
3. `activeEnd` for `.firstOn`: inside/outside the fired window; daemon-restart resume (latch set,
   now mid-window → block active).
4. Overlap: first-on `*0500-0900` (300 s) vs weekly `*0830` → clash; vs weekly `*0910` → clash
   (inside `end + duration`); vs weekly `*0906` with dur 300 → clash; vs `*1000` → ok; vs a
   onetime inside/outside the window.
5. Codable round-trip: old-format schedule decodes; new alarm round-trips with latch.

## Files touched

`Schedule.swift` (kind, latch, activeEnd, overlap) · `Enforcerd.swift` (trigger + inUse) ·
`State.swift` (SessionStore) · `Agent.swift` (lock observers + heartbeat) · `Commands.swift` +
`TimeSpec.swift` (parse, set, list, help) · `SelfTest.swift` · `README.md`. No installer, plist,
or permission changes. Install rides the same gate-window sudo session as the demonlock
reinstall (`sudo ./install.sh` re-deploys both services).
