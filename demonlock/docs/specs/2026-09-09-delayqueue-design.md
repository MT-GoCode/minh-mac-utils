# DelayQueue — one abstraction for every commitment-delayed change

**Date:** 2026-09-09 · **Status:** v4.3 — final; four adversarial passes (15 + 10 + 5 + 5 findings folded)

## Why

On 2026-09-07 Minh queued two zone edits from the map ("add 730 moreno", "delete
imbue office"). Neither landed. `DelayedChange` is a single-slot queue whose
payload is a full zones.json snapshot taken from *disk* at click time: the
second queue silently overwrote the first, reset the 36h clock, and its payload
didn't contain the first edit. Four clicks in 65s → three discarded, the
survivor was a no-op set. No history existed to show what happened.

There are eight commitment-delay systems across two daemons, hand-rolled in
three shapes with inconsistent semantics. This spec replaces the queue
MECHANICS with one abstraction, keeping each app's validation/apply bespoke.

An adversarial review (2026-09-09) found 15 defects in the v1 draft; all fixes
are folded in below and marked **[AR#n]** where the reasoning isn't obvious.

## Census

| # | System | Today | Target key | Failure |
|---|--------|-------|-----------|---------|
| 1 | demonlock `delayzones` | single slot, disk-snapshot payload (broken) | `add:<name>` / `del:<name>` ops | drop |
| 2 | demonlock `delay-set-policy` | single slot, whole doc | constant `policy` | drop |
| 3 | demonlock gate-policy | single slot, whole doc | constant `gate-policy` | drop |
| 4 | demonlock safe-apps register | name-keyed, requeue resets clock | name | drop |
| 5 | demonlock snooze-preset adds | name-keyed | name | drop |
| 6 | demonlock snooze-preset invoke | single slot, idempotent | constant `invocation` | drop |
| 7 | demonlock lockbox unlocks | name-keyed, per-entry delay | name | drop |
| 8 | nextdns-sidecar `delay-add` | domain-keyed, idempotent, retries (reference semantics) | domain | **retry** |

Policy and gate-policy use **constant keys**, not doc hashes **[AR#7]**: two
hash-keyed pending policies would be a pre-committed menu with free late
selection (abort one at hour 35, the other lands at 36) — more freedom than
today's single slot, where changing your mind costs a full clock reset. A
whole document is an *alternative*, not an independent item; constant key +
the replace+reset rule reproduces today's commitment semantics with multi-row
visibility everywhere it's actually wanted (zones, apps, presets, domains).

Ruled out: release valve (a grant, not a queue); lockbox add + all immediate
tightening paths (not delayed); `nextdns-delay-allow` in nextdns-discipline
(retired, not installed); `betterat` (general job scheduler, different
purpose); `delayed-snooze.json` (orphan file, deleted on upgrade).

## The abstraction

One file, `Sources/demonlock/DelayQueue.swift` (~250 lines), vendored verbatim
into nextdns-sidecar with a header naming demonlock as source of truth. No
shared package: two independently deployed root daemons stay build-independent.

```swift
struct DelayQueue {
    struct Item: Codable { var payload: String; var requestedAt: Double
                           var applyAt: Double; var seq: UInt64 }
    struct Outcome: Codable { var key: String; var what: String  // applied|rejected|aborted|replaced|failed
                              var reason: String?; var at: Double }
    struct QState: Codable { var pending: [String: Item] = [:]
                             var nextSeq: UInt64 = 0
                             var lastAppliedAt: Double?
                             var recent: [Outcome] = [] }   // last 8, newest first

    let kind: String            // log/status label, e.g. "zones"
    let stateFile: String       // root-owned JSON: QState
    let requestMarker: String   // user inbox, NDJSON: one payload per line
    let abortMarker: String     // user inbox: key per line; empty or "--all" = all
    let onFailure: Failure      // .drop | .retry
    enum Failure { case drop, retry }

    /// One daemon tick. Order: abort → request → apply-due (by seq).
    /// Never sleeps, never trusts user clocks.
    func tick(now: Double, enforcedUID: uid_t?, delaySec: (String) -> Double,
              key: (String) -> String?,          // payload → key; nil = reject that line
              validate: (String) -> Bool,        // at queue AND landing; fail-closed
              apply: (String) -> Bool) -> QStatus
}
```

Semantics, identical everywhere:

- **Multi-item, seq-ordered.** Every queued thing is its own row. A monotonic
  `seq` is stamped at consumption and is the sole apply order **[AR#1]** —
  `requestedAt` ties (same-tick del+add of a zone edit) would otherwise be
  broken by Swift dictionary iteration order, turning "move my zone" into
  "delete my zone" on a coin flip.
- **Requeue rule.** Same key + identical payload → ignored, clock kept.
  Canonicalisation before comparison, declared per queue by a
  `payloadIsJSON: Bool` knob — never sniffed from content [AR3#4]: JSON
  queues (zones, safe-apps, invoke) re-encode sorted-keys unpretty;
  non-JSON queues (policy, gate-policy, lockbox, sidecar domains) compare
  as trimmed UTF-8 bytes [AR2#7]. Non-JSON payloads may legally contain
  newlines (a multi-line policy expression tokenizes fine today) — writers
  escape `\n` as `\\n` on append and consumers unescape [R2], else NDJSON
  splitting would shred a multi-line policy into N individually-rejected
  fragments and the primary no-sudo path silently breaks — else a repeated `delay-set-policy` shell
  command would replace+reset and restart the longest clock in the system. Same key +
  different payload → replace payload AND reset clock, logged. Reset is
  mandatory: replace-keeping-the-clock would let a mild pending request be
  swapped for an aggressive one at hour 35 and land at 36.
- **Abort** by key or all. The abort marker is key-per-line. **Only a
  zero-byte marker FILE means abort-all** **[AR#4]** — every shipped
  `--abort` writes a zero-byte marker; without this rule each becomes a
  silent no-op after upgrade. A non-empty file aborts exactly the listed
  keys; **blank lines are skipped** [AR2#3] (a stray `\n` must never wipe
  the queue). A programmatic writer with nothing to abort must not write
  the marker at all. Aborts and replaces are always accepted, even at the
  cap **[AR#13]**.
- **Validate twice.** At queue and at landing, against live state. A line
  whose `key()` is nil or that fails validation is rejected *individually*;
  the rest of the batch proceeds. Invalid at landing → dropped, fail-closed.
- **Failure policy.** `.drop` or `.retry` next tick (sidecar only: a failed
  allow keeps the domain blocked, so retrying is safe).
- **Crash safety: save-before-apply for `.drop`** **[AR#3]**, with a
  **two-phase outcome** [AR2#4]: the pre-apply save moves the row out of
  `pending` and records `applying`; after `apply` returns, a second save
  rewrites it to `applied` or `failed`. A row still marked `applying` on
  the next tick is reported as `unconfirmed — may or may not have landed;
  not re-applied` [AR3#5] (a crash between apply-success and the second
  save is indistinguishable from one before apply; the label states what
  is actually known) and is never re-applied.
  So a crash between the saves loses the request (fail-closed, and
  VISIBLY: the audit never claims `applied` for a change that didn't land)
  instead of re-applying a loosening (fail-open — under v1's
  apply-then-save, a crash after a lockbox unlock applied would re-open a
  fresh copy window on a secret at next boot, unrequested). The
  two-phase `applying` outcome is scoped to `.drop` ONLY [AR3#3].
- **`.retry` ordering** [AR2#9]: remove-after-success — a crash between
  apply-success and save re-applies once, safe because the sidecar
  allowlist add is set-like (the only `.retry` user; any future `.retry`
  apply must be idempotent, stated in the vendored header). Retry logging
  is rate-limited; after 10 consecutive failures a `failed` outcome is
  recorded (the row keeps retrying; `--abort` frees its cap slot).
  `.retry` records `applied`/`failed` after the fact, no `applying` phase
  [AR3#3], and retries back off exponentially to a 5-minute floor
  (a permanently failing apply must not hit the NextDNS API at 1 Hz).
- **Daemon-stamped clocks.** `requestedAt`/`applyAt` set at consumption; not
  backdatable; nothing a user writes can make anything land sooner. If the
  clock moves backward past a row's `requestedAt` **by more than 300s**
  [AR2#8] (slack absorbs routine NTP boot steps), the row is re-stamped
  `now + delay` (fail-closed) and logged; forward jumps are
  indistinguishable from a long shutdown and land normally.
- **Audit.** Every queue / replace / abort / apply / reject / failure appends
  one line (key + ≤90-char preview) to `logs/queue-audit.log` — its own
  append-only file, not interleaved 1 Hz daemon stderr. `QState.recent`
  keeps the last 8 EVENTS per queue (a batch drop or a flush is one event
  listing its keys [AR2#10], so a 20-row flush can't evict all history at
  the moment the user goes looking) and status prints them
  (`last: add:home REJECTED (name exists) 4h ago`) **[AR#10]** — without
  this, a landing-time rejection 36h later is indistinguishable from "you
  never queued anything", the Sep-7 experience relocated.
- **Status.** All pending rows in seq order (key, preview, lands-in),
  `lastAppliedAt`, `recent`, and `queue full (64/64)` when capped. Every status surface and
  the map UI print the exact abort command next to each row.
- **No enforced user resolved** (fresh install): markers are skipped, but
  due items still apply — a queue must not strand because the uid cache is
  cold (today's behavior, kept).
- **Flush = discard.** `flushAll()` empties `pending` (logged, listing keys).
  The release-valve grant calls it on every demonlock queue **and calls
  `Lockbox.relockAll()`** **[AR#6]** — today's grant also relocks *open*
  secret windows (`unlockedUntil.removeAll()`), which lives outside the
  queue; naming it here keeps the port from dropping it. The flush includes
  a pending snooze-preset invocation (behavior change from today, deliberate:
  `snooze` is root-only, so with admin in hand you snooze via sudo; the
  grant supersedes the impulse queue). An ACTIVE snooze is untouched.
  Sidecar is a separate trust domain; demonlock's grant does not reach it.

### Marker I/O contract [AR#5, #12]

The request marker is NDJSON, one payload per line. v1 said "append" without a
contract; no current writer appends (`dropDelayMarker` truncates,
`ZonesUI.saveWithDelay` atomic-renames — the rename replaces the inode, and
the daemon's later `unlink` would delete a file it never read).

- **Writers:** one `write()` to `open(O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW)`,
  under `flock(LOCK_EX)`.
- **Daemon:** `MarkerIO.consume` takes `flock(LOCK_EX | LOCK_NB)` around
  read+unlink (after the fstat owner check, so the lock is never taken on a
  foreign inode). **Non-blocking is load-bearing** for the same reason as
  the existing O_NONBLOCK open: the inbox is user-owned, so a hostile
  process could hold a blocking flock forever and wedge the single-threaded
  root enforcer — a permanent enforcement DoS. On EWOULDBLOCK the marker is
  left for the next tick (writers hold the lock for microseconds) and the
  skip is logged at most once per minute.
- **Parsing:** only complete `\n`-terminated lines are processed; a trailing
  partial line is discarded and logged. At the 1 MiB cap the whole file is
  rejected with a log line — never act on a truncated prefix.
- **Single-value markers** (rv request, preset invoke, lockbox
  unlock/copy/add/remove, safe-app remove — every non-queue marker):
  consumers take the LAST non-empty complete line. Today these markers are
  last-write-wins via truncation; append would otherwise garble them
  (`"1800s\n3600s"` is not a duration) — a regression to the release
  valve. Flag markers (`consumeFlag`) stay existence-only, unchanged.

### Boundary layer: MarkerIO owns the trust boundary

All user→root inbox I/O lives in MarkerIO, both directions, no duplication:

- **`MarkerIO.append(path, line, mode: mode_t = 0o644)`** (new):
  O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW under flock(LOCK_EX), created with
  the given mode from the START. `dropDelayMarker` (Commands.swift:830 —
  the writer funnel for nearly every marker: rv request/abort, lockbox
  copy, removes, invoke) becomes a call to it, as does the raw write in
  `ZonesUI.saveWithDelay`. **Lockbox add is the second bespoke writer**
  [R1]: it carries a plaintext secret and today creates its marker 0600
  from the start (no umask-0644 window another local account could read);
  it calls append with `mode: 0o600` and MUST NOT concatenate — a pending
  add marker is single-value last-line like its siblings. A mechanical
  0644 port here would publish the secret; test asserts the marker is
  never readable by other.
  No code outside MarkerIO touches the inbox, ever.
- **`MarkerIO.consume`** gains LOCK_NB + NDJSON complete-line parsing once;
  every consumer — delay queues and immediate tightening paths alike —
  inherits the hardening.
- MarkerIO is vendored to nextdns-sidecar alongside DelayQueue, same
  source-of-truth header.
- The root→user direction (status: user session reads root-written 0644
  state; secrets via the 0600 lockbox outbox) is not attacker-writable and
  is unchanged.

Delay settability, restated as invariants: `set-delay` is root-only per
system; values live in root-owned settings.json; every USE clamps through
compiled-in Bounds floors (a tampered settings file cannot go below); the
daemon freezes `applyAt` at consumption, so no later write shortens a
pending row.

### Per-app knobs (closed set — nothing else)

| Knob | Values | Who deviates from default |
|------|--------|--------------------------|
| `key(payload)` | app closure | each app |
| `onFailure` | `.drop` (default) / `.retry` | sidecar delay-add |
| `delaySec(payload)` | app closure (constant from Settings, Bounds-clamped) | lockbox (per-entry delay) |
| `payloadIsJSON` | Bool (canonicalisation mode) | per census table |

Not knobs: requeue behavior, abort granularity, ordering, capacity. Cap: 64
pending per queue, **new keys only** — replaces and aborts always accepted
(otherwise a full queue makes a wrong pending geometry uncorrectable except
by abort + full clock restart). The cap never evicts. DoS note: the inbox is
writable by the enforced user only; filling the queue only rejects new
*loosenings* (fail-closed) and `--abort` (= all) clears it without sudo —
self-inflicted denial, not a bypass.

## Zones: operations, not snapshots

The map UI stops writing zones.json snapshots. A queued item is one op:

- payload `{"op":"add","zone":{...}}` → key `add:<name>`
- payload `{"op":"del","name":"..."}` → key `del:<name>`

Zone names are validated newline-free and non-empty at queue time (interior
newlines would corrupt NDJSON keys; today's UI only trims edges).

**Landing is batched, two phases, no retry loop [AR#2, AR2#2].** Per-op
validation would make every policy-referenced zone uneditable (edit =
del+add: the del alone rejects "referenced by policy", the add alone
collides — both drop, 36h wasted). A v2 "drop offending op and retry the
fold" loop was itself defective (could destroy an innocent op, and had no
defined outcome when no single removal fixes the fold). Instead:

- **Phase 1** — fold due ops in seq order into an in-memory copy of the
  live zone list. An op failing its OWN precondition is dropped there with
  a specific reason: bad geometry, `add` of an existing name, `del` of an
  absent name (no-op drop).
- **Phase 2** — **differential** validation of the resulting final list
  [AR3#1]: the batch fails only if it introduces a NEW unresolved
  policy/gate-policy reference (`unresolved(final) ⊄ unresolved(live)`) or
  a duplicate name. Pre-existing dangling references (the live policy
  already references "451 niantic ave", absent from zones.json) are logged
  once and ignored — absolute validation would drop every batch forever on
  a machine that is already inconsistent, in exactly the silent-drop mode
  this spec exists to kill. On failure the WHOLE batch is dropped,
  fail-closed, one audit line naming the new unresolved reference.

One atomic write on success — no transient window where a zone is missing
and the policy evaluates false → lockout.

- Zone *edit* (move/resize) = the UI queues `del:<name>` then `add:<name>`
  (two NDJSON lines, one append; seq preserves order).
- **"Save now (admin)"** still writes the full file immediately — and drops
  abort markers for `add:<name>`/`del:<name>` of every zone it touched
  **[AR#11]**, so a stale pending op can't silently revert an admin action
  12h later (safe-apps/presets already have this via `clearPending`; zones
  needs the analogue).

UI changes (`ZonesUI.swift`): queue ops; after queuing, reload and render
pending ops as rows/overlays "⏳ lands in 36h" with the exact abort command;
the delete path gets the reload it's missing today (its absence is why there
were four clicks in 65s).

## Cross-queue tick order and joint validation [AR#8, AR2#5]

Explicit tick order: **zones → policy → gate-policy → safe-apps → presets →
lockbox**. But order alone is a coin-flip trade (zones-first fixes
add-zone+referencing-policy and breaks del-zone+policy-landing-same-tick),
so zone/policy landings validate against a **joint projection**: final
zones (live + due ops) paired with final policy/gate-policy (due doc if
any, else live). If the projection (final zones + due doc) is invalid [AR3#2]: try
(LIVE zones + due doc) — if that validates, land the doc and drop the zone
batch (rejected, reason "conflicts with landing policy"); only if the doc
fails against live zones too is the doc dropped and the zone batch
re-tried differentially against the live doc. Both branches fail-closed;
this preference lands one change where a doc-first cascade would destroy
both. Tests assert: add-zone+referencing-policy lands together;
del-zone+doc-referencing-that-zone lands the doc, drops the del.

Queue ticks stay WHERE THEY ARE in `Enforcerd.tick`: before the standby
guards, so due items land regardless of who is logged in [R8] — moving
them into the evaluation path would strand every queue while logged out,
contradicting the "due items still apply" invariant. The release-valve
tick (and thus a grant's `flushAll`) runs AFTER the queue ticks: an item due in the same tick a grant lands applies first —
correct, since it landed before the grant existed; the audit may show an
apply and a flush in the same second.

## Restart safety

All state on disk, tick-driven, no timers (current architecture, kept).
Restart / reboot / sleep: overdue items land on the first tick after wake,
in seq order. NDJSON appended while the daemon is down is consumed on the
first tick up. State writes atomic; markers consumed under flock with
unlink-verify. Crash windows: save-before-apply means a crash can lose an
about-to-land request (fail-closed, logged absent) but never re-apply one.

## Migration [AR#9, #15]

Per-app `legacyDecode: (Data) -> [String: Item]?` closures — v1's "decode
into QState directly" is false for three of four shapes:

- Single-slot files (policy, gate-policy): `{payload, requestedAt, applyAt}`
  → one row, seq 0.
- Zones single-slot: the legacy payload is a whole-file snapshot that would
  need a special apply path bypassing op validation — **dropped + logged
  instead** (per adversarial review: the only thing that slot has ever held
  is the Sep-7 no-op set; a special path is creep and a validation bypass).
- safe-apps: `Pending.app` is a nested object → re-encoded canonically as
  the row payload, key = name.
- snooze-presets: `snooze-presets.json` holds TWO queues' state (`invocation`
  + `adds`); each DelayQueue occupies a named sub-object of the file,
  non-queue siblings preserved.
- lockbox: legacy `Pending` has no payload (payload:=key synthesized);
  `unlockedUntil` is NOT queue state and is preserved as a sibling —
  a naive whole-file rewrite would erase every open window's lifecycle.
- sidecar: same shape modulo `seq` (assigned in file order on first decode).

After any `legacyDecode`, `nextSeq = max(seq of migrated rows) + 1`, and
load asserts `nextSeq >` every pending seq [AR2#6] — otherwise migration
re-creates the ordering ties seq exists to kill.

`lastAppliedAt` carried over everywhere. `delayed-snooze.json` deleted.
File names and marker paths unchanged. **Downgrade** (old binary runs after
new state written): old `loadJSON` fails to decode the new shape → sees an
empty queue → its first save clobbers pending rows. Accepted and stated:
the loss direction is fail-closed (queued loosenings vanish, nothing lands
early).

## What stays bespoke (the do-not-unify list)

- Release valve: gate policy, eligibility window, grant/expiry/revoke.
- Lockbox unlock-window lifecycle (`unlockedUntil`, auto-relock,
  copy-consumes-window) — only the pending wait rides the queue; the grant
  additionally calls `relockAll()` (see Flush).
- Lockbox add (immediate), safe-app remove, preset remove, lockbox remove,
  sidecar arm/block — immediate tightening paths, plain marker reads.
- Snooze-preset invoke's target freezing (payload carries resolved
  `targetAt`, computed at queue time by app code). Note: invoke's apply is
  NOT idempotent (re-applying could extend a ceiling-clamped snooze or
  resurrect a cancelled one) — safe only because of save-before-apply.
- All validation and apply logic: policy parsing, zone geometry fold,
  NextDNS API, Admin grant — per-app closures.

## Testing

`swift test`, pure, temp files, no root:
- seq ordering: same-tick del+add zone edit lands as a move, deterministically,
  across simulated restarts (state reloaded between ticks).
- requeue: identical payload keeps clock; different payload replaces + resets;
  canonicalisation (CLI whitespace vs UI pretty-print) treated as identical.
- abort: by key, `--all`, empty payload = all; accepted at cap.
- batch fold: policy-referenced zone edit succeeds; offending-op drop +
  fold-retry; add-collision; del-missing.
- save-before-apply: simulated crash between save and apply loses the row,
  never double-applies (checked for lockbox-shaped and invoke-shaped applies).
- marker I/O: flock append vs consume race; partial trailing line discarded;
  1 MiB overflow rejects whole file; poison line rejected individually.
- cap: 65th new key rejected; replace of existing key accepted at 64.
- cross-queue: add-zone + referencing-policy land same tick.
- migration: every legacy shape; snooze-presets/lockbox sibling fields
  survive; zones legacy snapshot dropped + logged; downgrade clobber is
  fail-closed.
- clock: backward jump > 300s re-stamps; small NTP step doesn't; forward
  jump lands.
- flock: contended marker skipped non-blocking, consumed next tick;
  blocking-flock DoS impossible by construction (LOCK_NB asserted).
- abort: zero-byte file = all; file with blank lines skips them; listed
  keys only.
- outcome phases: `applying` row after simulated crash reports
  `lost in crash`, never re-applies; `apply`-returns-false records `failed`.
- joint validation: both cross-queue pairs (see above); differential
  phase 2 lands a batch despite a pre-existing dangling policy reference;
  `.retry` rows never get an `applying` outcome; backoff floor respected.
- migration nextSeq strictly above all migrated seqs.
- single-value markers: two appends between ticks → last wins (today's
  semantics); rv request round-trips under the new writer.
- lockbox add marker: created 0600, never other-readable, single-value.
- multi-line policy expression round-trips (escape/unescape) and stays
  idempotent on resubmit.
- lastAppliedAt: unchanged by pre-apply save, by `failed`, by
  `unconfirmed`; bumps only on success.

Manual on the Mac after install: queue rows round-trip, status/audit output,
abort commands printed by UI match working keys.

## Rollout

1. Land DelayQueue + demonlock port + tests; build, reinstall, verify live.
2. Re-queue the two lost zone edits (add 730 moreno, del imbue office) as ops.
3. Vendor into nextdns-sidecar, port delay-add, reinstall.
4. Separately: policy still references `451 niantic ave`, which doesn't
   exist in zones.json (predates this work) — fix by admin edit or queued
   op. NOT a prerequisite: phase-2 validation is differential, so the
   pre-existing dangling reference doesn't block the queue [AR3#1].
