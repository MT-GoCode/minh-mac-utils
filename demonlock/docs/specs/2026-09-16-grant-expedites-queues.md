# Admin grant expedites the self-serve queues (was: discards)

**Date:** 2026-09-16 · **Status:** v1 · corrects a misread of the user's intent in the DelayQueue spec

## Change

When the release valve **grants** admin, every pending self-serve row is **expedited** — landed on
the very next tick through the normal path — instead of discarded. Rationale: once you hold admin
you could make every one of those changes immediately with sudo anyway; making you redo them by
hand was pure friction, not protection. The user's word for it from day one was "admit all".

Unchanged: `arm` and `nosudo` (hardReset) still discard everything — those are *tightening* resets,
not grants. Aborts, replace-with-clock-reset, idempotent re-request, ordered landing, audit trail:
all unchanged.

## Mechanics

`DelayQueue.expediteAll(now:reason:)` — for every pending row set `applyAt = now`, record ONE
outcome `expedited` (keys joined, reason "admin grant"), save. That's it: the next tick's existing
`applyDue` sees them all due and applies them with the real per-surface validators, in seq order,
in the fixed cross-queue order zones → policy → gate-policy → safe-apps → presets → lockbox. A row
that fails validation at landing is rejected exactly as it would have been at hour 36 — expediting
never bypasses validation, only the wait.

`ReleaseValve.flushSelfServeQueues()` → renamed `expediteSelfServeQueues()`: calls `expediteAll` on
the same seven queues. **`Lockbox.relockAll()` is removed from the grant path** — an open unlock
window is an already-landed loosening the user requested; with admin held it's theirs to have. (It
stays in hardReset.) Log line: `release-valve: grant expedited N queued rows`.

`flushAll` stays (hardReset uses it).

### Same-tick ordering the expedite relies on
The grant fires inside the release-valve step of the enforcer tick. Queue ticks in the same enforcer
tick run *before* or *after* the valve? — **after must hold** for "lands next tick" to be true either
way; if the valve step runs after the queue steps, the rows land one tick later (≤1s). Either is
fine; the spec only promises "next tick or the one after". Verified in the plan by reading
`Enforcerd.tick` order.

### Edge cases
- **Nothing pending** → no-op, no outcome recorded.
- **Grant while a zone batch would collide** (e.g. `add:X` with X existing) → that row rejects at
  landing with the normal reason; the rest land.
- **Policy referencing a zone in the same expedited set** → lands, because zones apply before policy
  in the tick.
- **Repeated `i-still-need-sudo` extensions** don't re-fire the grant path (extension ≠ grant), so
  rows queued *during* a live grant wait their normal delay — or you apply them with sudo.
- **Crash between expedite-save and landing**: rows are simply due; they land on restart. Fail-safe.

## Files
`MacUtilsCore/Sources/MacUtilsCore/DelayQueue.swift` (+`expediteAll`) · `demonlock/…/ReleaseValve.swift`
(rename + body) · `demonlock/docs/specs/2026-09-09-delayqueue-design.md` (the "grant flushes" rows
→ "grant expedites"; relock note) · `demonlock/README.md` / `admin-release-valve help` wording.
The sidecar has no grant concept — untouched, but it links the new core (rebuild only).

## Tests
- `MacUtilsCoreTests`: `expediteAll` sets every `applyAt` to now, records one `expedited` outcome,
  no-ops on empty; a subsequent `applyDue(now:)` lands all rows in seq order.
- `DemonlockCoreTests`: grant path — two queues with pending rows → after `expediteSelfServeQueues`
  + one tick, both landed; lockbox window stays open across a grant; hardReset still discards.
- Gate: `demonlock help` / `admin-release-valve help` text diff; `_policytest` 49/49.

## Grant-time runbook (Thu 2026-09-17, 10:00–14:00 CEST — grant lands 10:00:01)

The binary that receives the 10:00 grant is the *installed* one, which **discards**. So:

**Before 10:00 (no sudo, do tonight):** nothing to queue — anything queued gets discarded at 10:00
by the old binary. Leave the 5 zone rows + the policy row as they are or abort them; irrelevant.

**At 10:00:30 — sudo, via `rac exec`, lid closed OK:**
1. `sudo demonlock admin-release-valve i-still-need-sudo "for 1h"` → start the 30-min extension loop.
2. `cd demonlock && sudo ./install.sh` → new binary (expedite + Part-1 folds already in it).
   Verify: `demonlock status` ARMED/verdict unchanged, grant intact, `admin-release-valve help`
   shows the new wording.
3. `cd nextdns-sidecar && sudo ./install.sh` and `cd blockrem && sudo ./install.sh` → the two
   binaries that predate the Part-1 folds (also relink the new core).
4. **Zones + policy, with sudo, immediately** (the queue was just discarded):
   `demonlock zones` admin-save: delete `imbue office`, `4100 ocean ave`, `the bay`; add
   `730 moreno`, `datology ai` (polygons re-drawn — the queued payloads are gone; I'll pull the
   polygon JSON out of `delayed-zones.json` *before* 10:00 so you can paste, not redraw).
   Then `sudo demonlock setpolicy 'TIME_IS_ANY([*0500-2015]) AND (NOT LOCATED_IN_ANY(["730 moreno", "irvine home", "chi tu san mateo place"]) OR TIME_IS_ANY([*0500-0900]))'`.
   Verify `demonlock status` evaluates with no unknown zone.
5. `install-all`-style verify by hand: `demonlock status`, `blockrem list`,
   `nextdns-sidecar networklockdown status`, `multistreamviewer status`, `demonlock test-lockout`.

**Lid open, you present:**
6. LockDown Browser → Privacy & Security ▸ Files and Folders ▸ Documents (or Full Disk Access).

**Then:** stop the loop, `rm ~/.gate-pw`, and `demonlock nosudo` if you're done with admin.

From this reinstall on, the next grant **expedites** whatever is queued instead of discarding it.
