# DelayQueue — one abstraction for every commitment-delayed change

**Date:** 2026-09-09 · **Status:** draft for review

## Why

On 2026-09-07 Minh queued two zone edits from the map ("add 730 moreno", "delete
imbue office"). Neither landed. `DelayedChange` is a single-slot queue whose
payload is a full zones.json snapshot taken from *disk* at click time: the
second queue silently overwrote the first, reset the 36h clock, and its payload
didn't contain the first edit. Four clicks in 65s → three discarded, the
survivor was a no-op set. No history existed to show what happened.

There are eight commitment-delay systems across two daemons, hand-rolled in
three shapes with inconsistent semantics (single slot vs name-keyed; requeue
resets clock vs idempotent vs ignored; abort granularity varies; only sidecar
retries failed applies; only some log). This spec replaces the mechanics with
one abstraction, keeping each application's validation/apply logic bespoke.

## Census

| # | System | Today | Target key | Failure |
|---|--------|-------|-----------|---------|
| 1 | demonlock `delayzones` | single slot, disk-snapshot payload (broken) | `add:<name>` / `del:<name>` **ops** | drop |
| 2 | demonlock `delay-set-policy` | single slot, whole doc | doc hash | drop |
| 3 | demonlock gate-policy | single slot, whole doc | doc hash | drop |
| 4 | demonlock safe-apps register | name-keyed, requeue resets clock | name | drop |
| 5 | demonlock snooze-preset adds | name-keyed | name | drop |
| 6 | demonlock snooze-preset invoke | single slot, idempotent | constant `"invocation"` | drop |
| 7 | demonlock lockbox unlocks | name-keyed, per-entry delay | name | drop |
| 8 | nextdns-sidecar `delay-add` | domain-keyed, idempotent, retries (reference semantics) | domain | **retry** |

Ruled out: release valve (a grant, not a queue); lockbox add + all immediate
tightening paths (not delayed); `nextdns-delay-allow` in nextdns-discipline
(retired, not installed); `betterat` (general job scheduler, different
purpose); `delayed-snooze.json` (orphan file, deleted on upgrade).

## The abstraction

One file, `Sources/demonlock/DelayQueue.swift` (~200 lines), vendored verbatim
into nextdns-sidecar with a header naming demonlock as source of truth. No
shared package: two independently deployed root daemons stay build-independent.

```swift
struct DelayQueue {
    struct Item: Codable { var payload: String; var requestedAt: Double; var applyAt: Double }
    struct QState: Codable { var pending: [String: Item] = [:]; var lastAppliedAt: Double? }

    let kind: String            // log/status label, e.g. "zones"
    let stateFile: String       // root-owned JSON: QState
    let requestMarker: String   // user inbox; contents = payload (one request per marker write)
    let abortMarker: String     // user inbox; contents = key, or "--all"
    let onFailure: Failure      // .drop | .retry
    enum Failure { case drop, retry }

    /// One daemon tick. Order: abort → request → apply-due (due items in
    /// requestedAt order). Never sleeps, never trusts user clocks.
    func tick(now: Double, enforcedUID: uid_t?, delaySec: (String) -> Double,
              key: (String) -> String?,          // payload → key; nil = invalid, reject
              validate: (String) -> Bool,        // at queue AND landing; fail-closed
              apply: (String) -> Bool) -> QStatus
}
```

Semantics, identical everywhere:

- **Multi-item.** `pending` is a map; every queued thing is its own row with its
  own clock.
- **Idempotent requeue.** Same key already pending → request ignored, original
  clock kept. (Double-clicks are harmless; nothing silently replaced. A
  *different* payload gets a different key, so nothing is lost either.)
- **Ordered landing.** Due items apply in `requestedAt` order, so interacting
  ops (add X then delete X) resolve the way they were requested.
- **Abort** by key or `--all`, consumed before requests (abort+requeue in one
  tick stays clean, as today).
- **Validate twice.** At queue and at landing, against live state. Invalid at
  landing → dropped (fail-closed), logged.
- **Failure policy.** `.drop` (all demonlock queues, current behavior) or
  `.retry` next tick (sidecar delay-add: a failed allow keeps the domain
  blocked, so retrying is safe).
- **Daemon-stamped clocks.** `requestedAt`/`applyAt` set by the daemon at
  marker consumption. Not backdatable. Nothing a user writes can make anything
  land sooner — the security invariant of the current code, preserved.
- **Audit log.** Every queue / abort / apply / reject / failure logs one line
  with the key and a ≤90-char payload preview. This is the history that didn't
  exist on Sep 7.
- **Status.** `QStatus` lists every pending row (key, preview, applyAt) plus
  `lastAppliedAt`. All status commands show it; `lastAppliedAt` is printed
  ("last landed 7h ago"), which today's `delayzones` omits.
- **Flush.** `flushAll()` empties `pending` (logged, listing dropped keys).
  The release-valve grant calls it on every demonlock queue — flush means
  *discard*, not apply: the queue is the no-admin path; with admin in hand you
  change things deliberately via sudo. Sidecar is a separate trust domain;
  demonlock's grant does not reach its queue.

Marker format: the request marker is NDJSON — one payload per line, appended
by writers (the user owns the inbox, so append is fine). The daemon consumes
the whole file and processes lines in order; same-tick requests share a
`requestedAt` and tie-break by line order. This fixes a latent bug in every
current system: two marker writes between ticks lose the first (atomic
overwrite). A zone edit (del+add written back to back) needs this.

### Per-app knobs (closed set — nothing else)

| Knob | Values | Who deviates from default |
|------|--------|--------------------------|
| `key(payload)` | app closure | each app |
| `onFailure` | `.drop` (default) / `.retry` | sidecar delay-add |
| `delaySec(payload)` | app closure (usually constant from Settings, clamped by Bounds) | lockbox (per-entry delay) |

Explicitly **not** knobs: requeue behavior (always idempotent), abort
granularity (always key + `--all`), ordering (always requestedAt), capacity
(unbounded map; single-slot behavior falls out of a constant key). A cap of 64
pending items per queue guards the root-owned file against no-sudo bloat
(reject + log beyond it), matching the lockbox's existing cap philosophy.

## Zones: operations, not snapshots

The map UI stops writing zones.json snapshots. A queued item is one op:

- payload `{"op":"add","zone":{...}}` → key `add:<name>`
- payload `{"op":"del","name":"..."}` → key `del:<name>`

Applied against the **live** zones file at landing time:

- `add`: geometry validated at queue and landing. Name-collision is checked
  at **landing only** (a queued del of the same name may land first — that's
  the edit flow); at landing an existing name → reject+drop (logged).
- `del`: name absent at landing → no-op drop (logged). Deleting a zone still
  referenced by the policy or gate-policy → reject+drop at landing (today an
  applied snapshot can orphan a policy reference — the current
  `"451 niantic ave"` indeterminate clause is this exact wound; validation now
  closes it for the delayed path).
- Zone *edit* (move/resize) = the UI queues `del:<name>` then `add:<name>`
  (one NDJSON append each, in that order). Ordered landing applies the del
  first, so the add lands clean.
- "Save now (admin)" keeps writing the full file immediately, unchanged.

UI changes (`ZonesUI.swift`): queue ops; after queuing, reload and render
pending ops as overlays/rows marked "⏳ lands in 36h"; the delete row shows
pending state (today it doesn't even reload — you can't tell it queued, which
is why there were four clicks).

CLI: `demonlock delayzones` lists rows — key, preview, lands-in, plus last
landed. `--abort <key>` cancels one; `--abort --all` cancels all. Same verbs
on `delay-set-policy --status/--abort`, `safe-apps show/abort`, etc.

## Migration

Lenient decoding on first run of the new daemon:

- Old single-slot `{pending:{payload,requestedAt,applyAt}}` → one `QState` row
  (key derived by the app's `key` closure; zones legacy snapshot gets key
  `legacy-snapshot` and applies as a whole-file write — nothing in flight is
  dropped by upgrading).
- Old name-keyed maps (safe-apps, presets, lockbox, sidecar) → same shape
  already; decode into `QState` directly.
- `delayed-snooze.json` deleted.
- File names/paths unchanged. Marker paths unchanged.

## What stays bespoke (the do-not-unify list)

- Release valve: gate policy, eligibility window, grant/expiry/revoke.
- Lockbox unlock-window lifecycle (`unlockedUntil`, auto-relock,
  copy-consumes-window) — only the pending wait rides the queue.
- Lockbox add (immediate), safe-app remove, preset remove, lockbox remove,
  sidecar arm/block — immediate tightening paths, plain marker reads.
- Snooze-preset invoke's target freezing (payload carries the resolved
  `targetAt`, computed at queue time by app code).
- All validation and apply logic: policy parsing, zone geometry, NextDNS API,
  Admin grant — per-app closures.

## Testing

`swift test` additions (pure, no root): DelayQueue tick driven with temp
files — idempotent requeue keeps clock; ordered landing of interacting zone
ops (add→del, del→add); abort key vs `--all`; validate-fails-at-landing drops;
`.retry` keeps entry; migration decodes each legacy shape; cap rejects the
65th item. Zones op-apply unit tests: add-collision, del-missing,
del-policy-referenced. One manual end-to-end on the Mac with `set-delay` at
the 12h floor is not practical to wait out; instead assert queue rows +
log lines after marker writes, and trust the tick math covered by unit tests.

## Rollout

1. Land DelayQueue + demonlock port + tests; build, reinstall, verify status
   output and queued-row round-trip live.
2. Re-queue the two lost zone edits (add 730 moreno, delete imbue office) as
   ops — they now coexist.
3. Vendor the file into nextdns-sidecar, port delay-add, reinstall.
4. Fix the stale-policy wound separately if desired: policy references
   `451 niantic ave`, which doesn't exist in zones.json (predates this work).
