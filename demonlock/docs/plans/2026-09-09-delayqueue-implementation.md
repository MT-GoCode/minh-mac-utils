# DelayQueue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **REQUIRED READING before any task:** the spec — `demonlock/docs/specs/2026-09-09-delayqueue-design.md` (v4.4). The spec is the semantic authority; this plan is the build order. Where they disagree, the spec wins and the disagreement is a bug in this plan.

**Goal:** Replace demonlock's three hand-rolled delay-queue shapes (and nextdns-sidecar's fourth) with one `DelayQueue` abstraction + one hardened `MarkerIO` boundary layer, per spec v4.4.

**Architecture:** A library target `DemonlockCore` holds all logic (testable via `swift test`); the executable is a one-line shim. `DelayQueue` owns queue mechanics behind a `QStateStore` seam (plain file or a field inside a composite file). Per-surface `key`/`validate`/`apply` closures stay in each subsystem. Zones/policy/gate-policy coordinate via read-only `peekDuePayload` for joint projection.

**Tech Stack:** Swift 5.9, Foundation (+ existing CoreLocation/AppKit/MapKit in moved files), swift-tools test target. Build/test happen on the Mac over SSH (no Swift toolchain on the VM).

## Global Constraints

- Repo: `MT-GoCode/minh-mac-utils`, branch **`delayqueue`** off `main`. Never push/merge to `main`; never install anything — install is a separate user-present gate-window step (spec Rollout).
- Dev loop: edit locally in this clone → commit → `git push -u origin delayqueue` → on the Mac: `git -C ~/code/minh-mac-utils fetch && git -C ~/code/minh-mac-utils worktree add -f ~/code/mmu-delayqueue delayqueue` (once), then `git -C ~/code/mmu-delayqueue pull` → `ssh mac-personal 'cd ~/code/mmu-delayqueue/demonlock && swift build && swift test'`.
- Every task ends with local commit; build+test on the Mac at least at each task's final step.
- Security invariants (spec, non-negotiable): root-owned state; daemon-stamped clocks; `applyAt` frozen at consumption; nothing a non-root write does lands anything sooner; `LOCK_NB` on all daemon-side flocks; lockbox-add marker mode 0600; all validation fail-closed.
- Constants (spec, verbatim): cap 64 pending/queue (new keys only); `recent` = 8 events; backward-clock slack 300 s; preview ≤ 90 chars; `.retry` failed-outcome after 10 consecutive failures; retry backoff exponential, 300 s ceiling; marker read cap 1 MiB (reject whole file at cap).
- Audit log: `Paths.queueAuditLog = Paths.logsDir + "/queue-audit.log"`, append-only, line format `[yyyy-MM-dd HH:mm:ss] <kind> <key> <WHAT>( — <reason>)?( · <preview>)?`.

---

### Task 0: Branch + Mac worktree + build baseline

**Files:** none (git only)

- [ ] `git checkout -b delayqueue` in the local clone; push `-u origin delayqueue`.
- [ ] On the Mac: create worktree `~/code/mmu-delayqueue` on `delayqueue`; run `swift build` in `demonlock/` — must succeed before any change (baseline).
- [ ] Sidecar divergence check: `diff -r ~/code/nextdns-build/nextdns-sidecar ~/code/mmu-delayqueue/nextdns-sidecar` (excluding `.build`). If the Mac's `nextdns-build` checkout (tracks a deleted branch) differs from `main`'s copy, STOP and reconcile: copy the newer files into the branch first, commit as `sidecar: sync from nextdns-build checkout`. Task 12 builds on `main`'s copy being current.
- [ ] Commit nothing else; this task is pure setup.

### Task 1: Package restructure — testable core

**Files:**
- Modify: `demonlock/Package.swift`
- Create: `demonlock/Sources/DemonlockCore/` (git mv of every file from `Sources/demonlock/` except `main.swift`)
- Create: `demonlock/Sources/DemonlockCore/Main.swift` (the old `main.swift` body as `public func demonlockMain()`)
- Modify: `demonlock/Sources/demonlock/main.swift` → `import DemonlockCore; demonlockMain()`
- Create: `demonlock/Tests/DemonlockCoreTests/SmokeTests.swift`

**Interfaces:**
- Produces: library `DemonlockCore` importable with `@testable import DemonlockCore`; single public symbol `demonlockMain()`.

- [ ] **Step 1:** Rewrite `Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "demonlock",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "DemonlockCore", path: "Sources/DemonlockCore",
            linkerSettings: [.linkedFramework("CoreWLAN"), .linkedFramework("CoreLocation"),
                             .linkedFramework("AppKit"), .linkedFramework("MapKit")]),
        .executableTarget(name: "demonlock", dependencies: ["DemonlockCore"], path: "Sources/demonlock"),
        .testTarget(name: "DemonlockCoreTests", dependencies: ["DemonlockCore"], path: "Tests/DemonlockCoreTests"),
    ]
)
```

- [ ] **Step 2:** `git mv` all sources except `main.swift` into `Sources/DemonlockCore/`. Move the `main.swift` switch body into `Sources/DemonlockCore/Main.swift` wrapped as `public func demonlockMain() { let argv = Array(CommandLine.arguments.dropFirst()); ... }` (body unchanged). New `Sources/demonlock/main.swift`: `import DemonlockCore\ndemonlockMain()`.
- [ ] **Step 3:** `SmokeTests.swift`:

```swift
import XCTest
@testable import DemonlockCore
final class SmokeTests: XCTestCase {
    func testBoundsClamp() { XCTAssertEqual(Bounds.clamp(0, Bounds.zonesDelay), 12.0 * 3600) }
}
```

- [ ] **Step 4:** Push; on Mac: `swift build && swift test` — both green, binary behaves (`.build/debug/demonlock help` prints help).
- [ ] **Step 5:** Commit `refactor: split DemonlockCore library + test target (no behavior change)`.

### Task 2: MarkerIO — append, NDJSON consume, LOCK_NB, escaping

**Files:**
- Modify: `demonlock/Sources/DemonlockCore/MarkerIO.swift`
- Modify: `demonlock/Sources/DemonlockCore/Commands.swift:830` (`dropDelayMarker`)
- Modify: `demonlock/Sources/DemonlockCore/Commands.swift:349-362` (lockbox add writer)
- Test: `demonlock/Tests/DemonlockCoreTests/MarkerIOTests.swift`

**Interfaces (Produces):**

```swift
enum MarkerIO {
    /// Append one line (newline added). Creates with `mode` from the start. flock(LOCK_EX) for the write.
    /// Escaping: "\\" → "\\\\", "\n" → "\\n" applied to `line` BEFORE writing (escape backslash first).
    @discardableResult static func append(_ path: String, line: String, mode: mode_t = 0o644) -> Bool

    /// Consume the marker file under flock(LOCK_EX|LOCK_NB) — EWOULDBLOCK ⇒ nil (left for next tick,
    /// log ≤1/min). Returns complete \n-terminated lines, UNESCAPED, in file order; trailing partial
    /// line discarded+logged; > 1 MiB ⇒ whole file rejected (unlinked, logged, returns nil).
    /// Zero-byte file ⇒ returns [] (non-nil — flag/abort-all signal). All existing owner/symlink/FIFO
    /// hardening kept. File is unlinked before return (unlink-verify), as today.
    static func consumeLines(_ path: String, enforcedUID: uid_t) -> [String]?

    /// Single-value markers: last non-empty line, or nil if absent/invalid. (= consumeLines, last.)
    static func consumeLast(_ path: String, enforcedUID: uid_t) -> String?

    static func consumeFlag(_ path: String, enforcedUID: uid_t) -> Bool   // unchanged semantics
}
```

The old `consume(_:enforcedUID:) -> Data?` is DELETED at the end of Task 10 (once no callers remain); until then it stays.

- [ ] **Step 1:** Write failing tests (temp dir, `getuid()` as enforcedUID):
  - `testAppendCreatesWithMode` (0600 stays 0600, never other-readable at any point)
  - `testAppendThenConsumeLines_roundTripsEscapedNewlines` (payload with `\n` and `\\`)
  - `testConsumeLastTakesLastNonEmpty` (two appends → last wins)
  - `testZeroByteFileReturnsEmptyArray`
  - `testTrailingPartialLineDiscarded` (write bytes w/o trailing `\n`)
  - `testOverMiBRejectsWholeFile`
  - `testHeldFlockSkipsNonBlocking` (child thread holds flock; consumeLines returns nil; file survives; succeeds after release)
  - `testSymlinkRefused`, `testWrongOwnerRefused` (existing hardening preserved; wrong-owner: chown unavailable unprivileged → simulate by expecting refusal path via fifo test `testFifoRefused` with mkfifo)
- [ ] **Step 2:** Run: `swift test --filter MarkerIOTests` — all FAIL (functions absent).
- [ ] **Step 3:** Implement `append` / `consumeLines` / `consumeLast` per the interface block. `append`: `open(path, O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW|O_CLOEXEC, mode)`, `flock(fd, LOCK_EX)`, single `write()` of escaped line + `\n`, `flock(LOCK_UN)`, close. `consumeLines`: existing open/fstat hardening → `flock(fd, LOCK_EX|LOCK_NB)`; on failure log-throttled nil; read loop with 1 MiB cap → on cap: unlinkHardened + log + nil; split on `\n`, drop trailing partial with log, unescape each line, unlinkHardened before return.
- [ ] **Step 4:** Rewrite `dropDelayMarker(path, payload: "")`: empty payload → `append(path, line: "")`? NO — empty abort = zero-byte FILE. Exact behavior: `payload.isEmpty ? (create-or-truncate zero-byte file via append with no write — implement as append(path, line: nil))`. Simplest compliant form:

```swift
func dropDelayMarker(_ path: String, payload: String = "") {
    if payload.isEmpty { _ = MarkerIO.append(path, line: nil) }   // ensure file exists, write nothing
    else { _ = MarkerIO.append(path, line: payload) }
}
```
  so `append` takes `line: String?` (nil ⇒ create only, no bytes). Update the interface block accordingly in code comments.
- [ ] **Step 5:** Lockbox add writer (`Commands.swift:349-362`): replace bespoke temp+rename with `MarkerIO.append(Paths.lbAddMarker, line: json, mode: 0o600)` — but single-value semantics: first `unlink(Paths.lbAddMarker)` then append (never concatenate two secrets; spec Boundary section). Add test `testLockboxAddMarkerNeverOtherReadable` in MarkerIOTests using the same unlink-then-append-0600 pattern.
- [ ] **Step 6:** `swift test` green on Mac. Commit `feat(markerio): append writer, NDJSON consume, LOCK_NB, escaping`.

### Task 3: DelayQueue core

**Files:**
- Create: `demonlock/Sources/DemonlockCore/DelayQueue.swift`
- Modify: `demonlock/Sources/DemonlockCore/Paths.swift` (add `queueAuditLog`)
- Test: `demonlock/Tests/DemonlockCoreTests/DelayQueueTests.swift`

**Interfaces (Produces — every later task consumes these exact names):**

```swift
struct DelayQueue {
    struct Item: Codable, Equatable {
        var payload: String; var requestedAt: Double; var applyAt: Double; var seq: UInt64
        var retries: UInt32 = 0            // .retry bookkeeping; lenient-decoded
        var nextRetryAt: Double? = nil
    }
    struct Outcome: Codable, Equatable { var key: String; var what: String; var reason: String?; var at: Double }
        // what ∈ queued|replaced|aborted|applying|applied|rejected|failed|unconfirmed|flushed|lost
        // batch/flush events: key = keys joined ", " (ONE Outcome per event — spec [AR2#10])
    struct QState: Codable {
        var pending: [String: Item] = [:]; var nextSeq: UInt64 = 0
        var lastAppliedAt: Double? = nil; var recent: [Outcome] = []
    }
    struct Row: Codable { var key: String; var preview: String; var applyAt: Double; var seq: UInt64 }
    struct QStatus: Codable {
        var kind: String; var rows: [Row]           // seq order
        var lastAppliedAt: Double?; var recent: [Outcome]; var full: Bool
    }
    struct QStateStore {                            // the composite-file seam (Tasks 8/9)
        let load: () -> QState; let save: (QState) -> Void
        static func file(_ path: String, legacyDecode: ((Data) -> (rows: [String: Item], lastAppliedAt: Double?)?)? = nil) -> QStateStore
    }
    enum Failure { case drop, retry }

    let kind: String; let store: QStateStore
    let requestMarker: String; let abortMarker: String
    let onFailure: Failure; let payloadIsJSON: Bool

    static let cap = 64
    static let clockSlackSec = 300.0
    static let retryBackoffCeilSec = 300.0
    static let retryFailedOutcomeAfter: UInt32 = 10

    /// Canonicalise for identity comparison. payloadIsJSON: re-encode via JSONSerialization
    /// (.sortedKeys, no pretty); decode failure ⇒ fall back to trimmed bytes. Else trimmed UTF-8.
    func canonical(_ payload: String) -> String

    /// Read-only: the due payloads at `now`, seq order, without consuming anything (joint projection).
    func peekDue(now: Double) -> [(key: String, payload: String)]

    /// One tick. Order (spec): abort → request → clock-guard → apply-due (seq order).
    /// `applyBatch` receives ALL due items (seq order) and returns per-key verdicts; keys absent
    /// from the result are treated as (ok: false, reason: "no verdict") — fail-closed.
    func tick(now: Double, enforcedUID: uid_t?,
              delaySec: @escaping (String) -> Double,
              key: @escaping (String) -> String?,
              validate: @escaping (String) -> Bool,
              applyBatch: @escaping (_ due: [(key: String, payload: String)]) -> [String: (ok: Bool, reason: String?)]
    ) -> QStatus

    /// Per-item convenience: wraps `apply` into an applyBatch.
    func tick(now: Double, enforcedUID: uid_t?, delaySec: @escaping (String) -> Double,
              key: @escaping (String) -> String?, validate: @escaping (String) -> Bool,
              apply: @escaping (String) -> Bool) -> QStatus

    /// Discard all pending (grant flush / abort-all). Logs ONE flushed event listing keys.
    func flushAll(now: Double, reason: String)

    func status() -> QStatus                        // read-only, for CLI paths that don't tick
}
```

Tick semantics (implement exactly; spec section "Semantics"):
1. **Abort:** `consumeLines(abortMarker)`. `[]` (zero-byte) ⇒ abort ALL (one `flushed` event, reason "abort --all"). Non-empty ⇒ for each non-blank line, drop that key (+`aborted` outcome each; unknown key ⇒ `rejected` outcome reason "no such pending key"). Blank lines skipped.
2. **Requests:** `consumeLines(requestMarker)`, in file order. Per line: `key(line)` nil ⇒ `rejected` ("unkeyable"); `validate` false ⇒ `rejected` ("invalid at queue"); existing key + `canonical` equal ⇒ silently ignore (no outcome — double-click); existing key + different ⇒ replace payload, `requestedAt=now`, `applyAt=now+delaySec(line)`, new seq, `replaced` outcome; new key at cap ⇒ `rejected` ("queue full 64/64"); else insert Item(now, now+delay, seq: nextSeq++), `queued` outcome.
3. **Clock guard:** any pending `requestedAt > now + 300` ⇒ re-stamp `requestedAt=now, applyAt=now+delaySec(payload)`, log.
4. **Apply-due:** due = pending where `now >= applyAt` (for `.retry` also `now >= nextRetryAt ?? 0`), seq-sorted. Re-`validate` each; invalid ⇒ remove + `rejected` ("invalid at landing"). Then:
   - `.drop`: remove ALL surviving due rows from `pending`, write `applying` outcomes, **save state** (spec save-before-apply); call `applyBatch`; rewrite each outcome to `applied` (bump `lastAppliedAt=now`, success only) or `failed(reason)`; save again. On next tick, any lingering `applying` outcome (only possible after a crash) is rewritten `unconfirmed` and logged — never re-applied.
   - `.retry`: call `applyBatch` with rows still in `pending`; ok ⇒ remove + `applied` + bump `lastAppliedAt`; !ok ⇒ `retries += 1`, `nextRetryAt = now + min(300, 5 * pow(2, retries))`, log throttled, `failed` outcome once at `retries == 10`. Rows never get `applying`.
5. `enforcedUID == nil` ⇒ skip steps 1–2, still run 3–4 (spec: due items must land on a cold uid cache).
6. Every outcome also appends an audit line to `Paths.queueAuditLog` (0644 root; `preview()` = first 90 chars, newlines→spaces — reuse the shape of `DelayedChange.preview`).
7. `recent` = last 8 outcomes, newest first, where one batch/flush = one Outcome.

- [ ] **Step 1:** Write failing tests (all pure: temp files, injected closures, no root):
  - `testQueueLandsAfterDelay`, `testSeqOrderDeterministicAcrossReload` (queue del+add same tick, reload QState from disk between every tick, assert order 100×)
  - `testIdenticalPayloadIdempotent_JSONWhitespace` (pretty vs compact JSON, clock kept), `testIdenticalNonJSONBytes`
  - `testDifferentPayloadReplacesAndResets`, `testReplaceAcceptedAtCap`, `test65thKeyRejected`, `testAbortAcceptedAtCap`
  - `testAbortByKey`, `testAbortAllOnZeroByteFile`, `testAbortBlankLinesSkipped`, `testAbortUnknownKeyRejectedOutcome`
  - `testSaveBeforeApply_crashLosesRowNeverReapplies` (simulate: run tick with applyBatch that records call then "crash" = discard post-state; new DelayQueue over same store; assert row gone, apply not re-called, `unconfirmed` in recent)
  - `testApplyFalseRecordsFailed`, `testLastAppliedAtOnlyOnSuccess` (unchanged by applying/failed/unconfirmed)
  - `testRetryKeepsRowWithBackoff` (5,10,20…300 ceiling), `testRetryFailedOutcomeAtTen`, `testRetryNeverApplying`, `testRetryCrashAfterSuccessReappliesOnce_setLikeSafe`
  - `testClockBackward400sRestamps`, `testClockBackward100sDoesNot`, `testForwardJumpLands`
  - `testRecentIsEightEvents_flushIsOne` (flush 20 rows → 1 event), `testAuditLineWritten`
  - `testNilEnforcedUIDStillApplies`, `testPeekDueMatchesApplyOrder`, `testPoisonLineRejectedIndividually` (key() nil for one of three lines; other two queue)
- [ ] **Step 2:** `swift test --filter DelayQueueTests` — FAIL.
- [ ] **Step 3:** Implement `DelayQueue.swift` (~250 lines) per interfaces + semantics above. Add `Paths.queueAuditLog`.
- [ ] **Step 4:** `swift test` green (Mac). Commit `feat: DelayQueue core`.

### Task 4: Migration decoders

**Files:**
- Modify: `demonlock/Sources/DemonlockCore/DelayQueue.swift` (`QStateStore.file(_:legacyDecode:)` wiring: on QState decode failure try legacyDecode; set `nextSeq = maxSeq+1`; assert on load `nextSeq > all pending seq` — violation: log + fix up, never crash the daemon)
- Create: `demonlock/Sources/DemonlockCore/DelayQueueMigration.swift` — the per-surface closures:
- Test: `demonlock/Tests/DemonlockCoreTests/MigrationTests.swift`

**Interfaces (Produces):**

```swift
enum Legacy {
    /// {payload, requestedAt, applyAt} single slot (policy, gate-policy). key from `constKey`.
    static func singleSlot(constKey: String) -> (Data) -> (rows: [String: DelayQueue.Item], lastAppliedAt: Double?)?
    /// zones single slot: pending DROPPED + audit-logged (spec Migration); lastAppliedAt carried.
    static func zonesDropSnapshot() -> (Data) -> (rows: [String: DelayQueue.Item], lastAppliedAt: Double?)?
    /// safe-apps {pending: {name: {app, requestedAt, applyAt}}} → payload = canonical SafeApp JSON.
    static func safeApps() -> (Data) -> (rows: [String: DelayQueue.Item], lastAppliedAt: Double?)?
    /// sidecar {pending: {domain: {requestedAt, applyAt}}} → payload = domain (payload:=key).
    static func keyOnlyMap(field: String = "pending") -> (Data) -> (rows: [String: DelayQueue.Item], lastAppliedAt: Double?)?
}
```

(snooze-presets & lockbox migrate inside their composite containers — Tasks 8/9.)

- [ ] **Step 1:** Failing tests: feed byte-exact legacy JSON fixtures (copy real shapes from `DelayedChange.swift`/`SafeApps.swift`/sidecar `Daemon.swift` structs) → decode → assert rows/keys/times/lastAppliedAt; `testZonesLegacyPendingDroppedAndLogged`; `testNextSeqAboveAllMigrated`; `testNewShapeRoundTripsUntouched`; `testCorruptFileYieldsEmptyQState` (fail-closed, like today's loadJSON).
- [ ] **Step 2:** FAIL → implement → PASS → commit `feat: DelayQueue legacy migration`.

### Task 4.5: Status-surface skeleton (keeps every later commit compiling)

**Why:** `DelayedStatus` is consumed by `Agent.swift:77`, `Commands.swift:101`,
`Enforcerd.swift:32-34`, `State.swift:50-52`. Deleting `DelayedChange.swift`
in Task 6 before the consumers are retyped would break every intermediate
commit between Tasks 6 and 11. This task makes the migration ADDITIVE.

**Files:**
- Modify: `demonlock/Sources/DemonlockCore/State.swift` (add the seven new
  `DelayQueue.QStatus?` fields from Task 11's interface block, all `= nil`;
  KEEP the legacy fields for now)
- Modify: `demonlock/Sources/DemonlockCore/Agent.swift:77-91`
  (`handleDelayedApplied(_ items: [(String, Double?)])` — retyped ONCE here;
  call sites pass `legacy?.lastAppliedEpoch` until each port task switches
  its tuple to `qstatus?.lastAppliedAt`)
- Modify: `demonlock/Sources/DemonlockCore/Commands.swift` (add
  `printQueueStatus` from Task 5 Step 3 here instead; `statusBody` renders a
  new-field section only when non-nil, legacy lines otherwise)

- [ ] **Step 1:** Make the additive changes above; `swift build && swift test` green.
- [ ] **Step 2:** Commit `refactor: additive QStatus surface (legacy status kept alive)`.

**Rule for Tasks 5-10:** each port task (a) fills its new StateSnapshot
field, (b) switches ITS consumers (statusBody section, handleDelayedApplied
tuple, CLI reader) to the new field, and (c) deletes ITS legacy Status
type/field in the same task. `DelayedStatus` + `DelayedChange.swift` die in
Task 6 (their last consumer, zones, converts there). Task 11 shrinks to a
sweep: assert no legacy status type remains, delete stragglers.

### Task 5: Policy + gate-policy port

**Files:**
- Modify: `demonlock/Sources/DemonlockCore/Enforcerd.swift:451-487` (`runDelayedChanges`)
- Modify: `demonlock/Sources/DemonlockCore/Commands.swift:26-49` (`handleRequestFlags`), `:755-798` (`runDelaySetPolicy`), `:700-730` (gate-policy subcommands)
- Delete: `demonlock/Sources/DemonlockCore/DelayedChange.swift` (at end of Task 6, when zones no longer needs it)
- Test: `demonlock/Tests/DemonlockCoreTests/PolicyQueueTests.swift`

**Interfaces:**
- Consumes: `DelayQueue`, `MarkerIO.append`, `PolicyEngine.validate(_:zones:allowInPolicy:) throws`, `PolicyStore.write`, `ReleaseValveConfig`.
- Produces: `Enforcer` properties `dpPolicyStatus/dpZonesStatus/dpGatePolicyStatus: DelayQueue.QStatus?` (renamed types, same names); queue instances as `Enforcer` lets:

```swift
static func policyQueue() -> DelayQueue   // kind "policy",   store .file(Paths.delayedPolicyFile, legacyDecode: Legacy.singleSlot(constKey: "policy")),   markers dsp*, .drop, payloadIsJSON: false
static func gatePolicyQueue() -> DelayQueue // kind "gate-policy", analogous (constKey "gate-policy"), markers dgp*
static func zonesQueue() -> DelayQueue    // kind "zones", .file(Paths.delayedZonesFile, legacyDecode: Legacy.zonesDropSnapshot()), markers dz*, .drop, payloadIsJSON: true
```

- [ ] **Step 1:** Failing tests: policy queue end-to-end with temp Paths override (inject store/markers directly — construct DelayQueue with temp paths, don't touch real Paths): constant key ⇒ second different doc replaces+resets; identical resubmit idempotent; multi-line doc round-trips (escaping from Task 2) and validates; landing validates against injected zones list; apply writes the doc.
- [ ] **Step 2:** Implement `runDelayedChanges` using the three queues:
  - zones tick FIRST, then policy, then gate-policy (spec order; zones' applyBatch arrives in Task 6 — until then wire zones with a temporary per-item apply that whole-file-writes, kept compiling, replaced next task).
  - policy: `key = { _ in "policy" }`, `validate = { (try? PolicyEngine.validate($0, zones: ZoneStore.load())) != nil }`, `apply = { (try? PolicyStore.write($0)) != nil }`, `delaySec = { _ in Bounds.clamp(settings.policyDelaySec, Bounds.policyDelay) }`.
  - gate-policy analogous with `allowInPolicy: true`, apply into `ReleaseValveConfig`.
- [ ] **Step 3:** CLI: `runDelaySetPolicy` writes via `dropDelayMarker` (now append+escape — no other change); `handleRequestFlags` unchanged for `--abort` (zero-byte = all, already correct); ADD `--abort <key>` passthrough: if an arg follows `--abort`, write it as the line. Same for gate-policy and (Task 6) delayzones. Status printers switch to `printQueueStatus` (defined in Task 4.5) with
format:

```
  1. <key>   lands <fmtWhen> (<Xh Ym left>)   abort: <abortCmd> "<key>"
  last: <key> <WHAT> (<reason>) <rel time>      (from recent)
  last landed <rel>   ·   queue full (64/64) when full
```
- [ ] **Step 4:** `swift build && swift test` green. Commit `feat: policy + gate-policy on DelayQueue`.

### Task 6: Zones — ops, two-phase fold, joint projection

**Files:**
- Create: `demonlock/Sources/DemonlockCore/ZoneOps.swift`
- Modify: `demonlock/Sources/DemonlockCore/Enforcerd.swift` (`runDelayedChanges` zones wiring)
- Modify: `demonlock/Sources/DemonlockCore/Commands.swift:800-828` (`printDelayZonesStatus`/`runDelayZones` → QStatus + `--abort <key>`)
- Delete: `demonlock/Sources/DemonlockCore/DelayedChange.swift`
- Test: `demonlock/Tests/DemonlockCoreTests/ZoneOpsTests.swift`

**Interfaces (Produces):**

```swift
struct ZoneOp: Codable, Equatable {           // the queue payload (payloadIsJSON: true)
    var op: String                             // "add" | "del"
    var zone: Zone? = nil                      // add
    var name: String? = nil                    // del
    var opKey: String? { op == "add" ? zone.map { "add:\($0.name)" } : name.map { "del:\($0)" } }
    static func decode(_ payload: String) -> ZoneOp?
}
enum ZoneOps {
    /// Queue-time validation: decodable; name non-empty, newline-free; add: geometry sane
    /// (circle radius > 0; polygon ≥3 points, simple — reuse ZonesUI.isSimplePolygon, move it here).
    static func validateAtQueue(_ payload: String) -> Bool
    /// Spec "Landing is batched" + "joint validation". Pure: no I/O.
    /// Returns final list + per-key verdicts + whether the due doc conflicted (docWins).
    static func fold(due: [(key: String, payload: String)], live: [Zone],
                     livePolicy: String?, liveGatePolicy: String?,
                     duePolicyDoc: String?, dueGateDoc: String?)
        -> (final: [Zone]?, verdicts: [String: (ok: Bool, reason: String?)])
}
```

`fold` algorithm (spec Zones + Cross-queue, implement verbatim):
1. Phase 1: fold in seq order into copy of `live`; per-op precondition failures dropped with reason (`bad geometry` / `name exists` / `no such zone`).
2. Projection docs: `P = duePolicyDoc ?? livePolicy`, `G = dueGateDoc ?? liveGatePolicy`.
3. Phase 2 (differential): `newUnresolved = unresolved(final, P, G) − unresolved(live, livePolicy, liveGatePolicy)`; also duplicate-name check on final. If `newUnresolved` empty → success.
4. Else if a due doc exists AND it validates against LIVE zones (`unresolved(live, dueDoc…) ⊆ unresolved(live, liveDocs)`) → the doc wins: whole zone batch dropped, every surviving key gets `(false, "conflicts with landing policy")`, `final = nil`.
5. Else → re-run step 3 with live docs only; if still new unresolved → whole batch `(false, "would orphan policy reference <name>")`, `final = nil`.
`unresolved(zones, policy, gate)` = zone names referenced by either doc that aren't in `zones` (expose a small `PolicyEngine.referencedZones(_ s: String) -> Set<String>` — parse-only, add to Policy.swift).

Enforcerd wiring: zones tick uses `applyBatch = { due in let r = ZoneOps.fold(due: due, live: ZoneStore.load(), livePolicy: PolicyStore.text(), liveGatePolicy: ReleaseValveConfig.load().gatePolicy, duePolicyDoc: policyQ.peekDue(now:).first?.payload, dueGateDoc: gateQ.peekDue(now:).first?.payload); if let f = r.final { write zones.json atomically (existing write shape, chmod 644) or mark all failed on write error }; return r.verdicts }`.

- [ ] **Step 1:** Failing tests (pure `fold`): move-edit lands (del+add same name, policy references it); add-collision dropped; del-missing no-op-dropped; bad-geometry dropped, siblings proceed; whole-batch drop names the orphaned reference; pre-existing dangling ref ("451 niantic ave" fixture) does NOT block; add-zone + due-policy-referencing-it → both land (fold ok under due doc; policy lands its own tick — assert fold verdict ok); del-zone + due-doc-referencing-it → doc wins, batch dropped w/ "conflicts with landing policy"; doc invalid against live too → batch retried against live docs.
- [ ] **Step 2:** FAIL → implement `ZoneOps` + `PolicyEngine.referencedZones` → PASS.
- [ ] **Step 3:** Wire Enforcerd (zones→policy→gate-policy order stays at Enforcerd.swift:84, before standby guards — do not move); delete `DelayedChange.swift`; update `runDelayZones` (bare/`--status` → `printQueueStatus(dpZonesStatus-from-state.json…` — CLI reads `StateSnapshot`; see Task 11 for the field). CLI `--abort <key>` writes the key line.
- [ ] **Step 4:** Build + full `swift test` green. Commit `feat: zones as ops with two-phase fold + joint projection`.

### Task 7: ZonesUI — queue ops, show pending, admin-save aborts

**Files:**
- Modify: `demonlock/Sources/DemonlockCore/ZonesUI.swift` (`saveZone`, `deleteSelected`, `saveWithDelay`, `reload`, instr text; `isSimplePolygon` moved out in Task 6 — import from ZoneOps)

**Interfaces:** Consumes `ZoneOp`, `MarkerIO.append`, `StateStore.read()?.delayedZones` (QStatus, Task 11 field — until Task 11 lands, read may be nil; code must tolerate nil).

- [ ] **Step 1:** `saveWithDelay(_ op: ZoneOp) -> Bool` = `MarkerIO.append(Paths.dzRequestMarker, line: opJSON)`. `saveZone` delayed branch queues `ZoneOp(op:"add", zone: newZone)`; `deleteSelected` delayed branch queues `ZoneOp(op:"del", name: name)` **and calls `reload()`** (the missing reload). Instr strings: include exact abort command `demonlock delayzones --abort "add:<name>"`.
- [ ] **Step 2:** Pending display: `reload()` also reads `StateStore.read()?.delayedZones?.rows` and appends a line per pending op to the instr/label area (`⏳ add:730 moreno — lands in 35h 12m · abort: demonlock delayzones --abort "add:730 moreno"`). Minimal text UI, no new views.
- [ ] **Step 3:** `saveWithAdmin` (both call sites): after a successful admin write, for each zone name in the symmetric difference (old live vs new list), if `StateStore.read()?.delayedZones?.rows` contains `add:<name>` or `del:<name>`, append those key lines to `Paths.dzAbortMarker`; write NOTHING when no keys match (spec [AR2#3]).
- [ ] **Step 4:** Build on Mac (UI is compile-verified here; live check is Task 13). Commit `feat(zones-ui): queue ops, show pending, admin-save cancels stale ops`.

### Task 8: Snooze-presets port (composite file, two queues)

**Files:**
- Modify: `demonlock/Sources/DemonlockCore/SnoozePresets.swift`
- Test: `demonlock/Tests/DemonlockCoreTests/SnoozePresetsQueueTests.swift`

**Interfaces (Produces):**

```swift
// snooze-presets.json container — replaces SPState; legacy fields consumed once:
struct SPFile: Codable {
    var invocation: SnoozePresets.Invocation? = nil        // legacy (migrated then nil)
    var adds: [String: SnoozePresets.AddPending]? = nil    // legacy (migrated then nil)
    var invokeQ: DelayQueue.QState? = nil
    var addsQ: DelayQueue.QState? = nil
}
// Queues (QStateStore closures over SPFile load/save; single read+write per tick):
//   invoke: kind "snooze-invoke", markers spInvoke*, key = {_ in "invocation"}, payloadIsJSON: true
//     payload = {"name": <preset>, "targetAt": <epoch frozen at QUEUE time by the daemon tick's key/validate step>}
//     — freezing: the CLI writes just the NAME; the queue's `key` closure is given the raw line; the
//     VALIDATE closure resolves the preset and REWRITES the payload? NO — closures can't rewrite.
//     Resolution: the invoke REQUEST line is the name; `key` returns "invocation" if the preset exists
//     else nil (rejected); delaySec = preset.invokeDelaySec clamp; the frozen target is computed at
//     APPLY time as `min(parseTarget(spec) at queue…)` — cannot be, target must freeze at queue.
//     FINAL DESIGN: payload transformation hook `enqueueTransform: ((String) -> String?)?` on DelayQueue
//     (nil for every other queue): maps the raw line to the stored payload at queue time, nil ⇒ reject.
//     invoke uses it to resolve name → {"name":…, "targetAt": parseTarget(spec).epoch}. Add to Task 3
//     interfaces + one test (testEnqueueTransformAppliedOnce; replace/idempotent compare uses the
//     TRANSFORMED payload).
//   adds:   kind "snooze-preset-add", markers spAdd*, key = preset name from JSON, payloadIsJSON: true
```

Apply closures: invoke — decode payload, cap at `now + Bounds.snoozeDurationMax`, `SnoozeStore.set`, re-arm if disarmed (today's lines 108-115 verbatim); adds — `rejectReason == nil` gate then `applyAdd`. Immediate paths (`spRemoveMarker` remove + kill pending add; `spInvokeAbort` → abort marker of invokeQ) stay in `SnoozePresets.tick`, now via `consumeLast`/abort lines. `clearPendingAdd` becomes an abort-marker append (key = name) from the CLI immediate-add path.

- [ ] **Step 1:** Failing tests: legacy SPFile with in-flight invocation + two adds migrates (rows present, siblings gone after first save, nextSeq sane); invoke idempotent while pending; DIFFERENT preset while pending ⇒ replace+reset (spec requeue rule); target frozen at queue time (advance mock clock past midnight boundary; assert targetAt unchanged); apply caps at ceiling; add lands into Settings mutation (temp settings path — `Settings.mutate` writes real path? inject: `applyAdd` already goes through `Settings.mutate`; for the test assert via the closure result contract instead — wrap apply in a spy).
- [ ] **Step 2:** FAIL → implement (including `enqueueTransform` back in DelayQueue + its Task-3 tests) → PASS. Commit `feat: snooze-presets on DelayQueue (invoke + adds)`.

### Task 9: Lockbox port + relockAll

**Files:**
- Modify: `demonlock/Sources/DemonlockCore/Lockbox.swift`
- Test: `demonlock/Tests/DemonlockCoreTests/LockboxQueueTests.swift`

**Interfaces (Produces):**

```swift
struct LBFile: Codable {                       // lockbox-state.json container
    var pending: [String: Lockbox.Pending]? = nil      // legacy (migrated then nil)
    var unlockedUntil: [String: Double] = [:]          // SIBLING — never queue state
    var unlocksQ: DelayQueue.QState? = nil
}
// unlocks queue: kind "lockbox-unlock", markers lbUnlock*/lbAbort*, key = payload (name),
//   payloadIsJSON: false, delaySec = { name in max(entry.delaySec, Bounds.lockboxUnlockDelayMin) },
//   validate = entry exists && not already unlocked, apply = { unlockedUntil[name] = now + Bounds.lockboxAutoRelock }
static func relockAll()                        // clears unlockedUntil (grant path; Task 10)
```

Copy / remove / add / auto-relock stay bespoke in `Lockbox.tick` (spec do-not-unify), reading markers via `consumeLast`. `Status`/`EntryView` unchanged except `unlockAtEpoch` now read from `unlocksQ` rows.

- [ ] **Step 1:** Failing tests: unlock queues with per-entry delay ≥ floor; crash-between-saves does NOT resurrect a window (save-before-apply — the R# scenario: apply sets unlockedUntil, but row was removed pre-apply; simulate crash by dropping the post-save; assert next tick has no window AND no re-apply); abort relocks + cancels; re-add resets pending + window (existing behavior kept); migration preserves `unlockedUntil` sibling byte-for-byte.
- [ ] **Step 2:** FAIL → implement → PASS. Commit `feat: lockbox unlocks on DelayQueue + relockAll`.

### Task 10: Safe-apps port + grant flush wiring

**Files:**
- Modify: `demonlock/Sources/DemonlockCore/SafeApps.swift` (registry → `zonesQueue`-style file queue; kind "safe-apps", markers saRegister*/saAbort*, key = `app.name`, payloadIsJSON: true, validate = existing register checks (blocklist, team rules — reuse the current register-path validation function), apply = today's registration `Settings.mutate`; immediate remove stays bespoke incl. `clearPending(bid:)` → abort-line append)
- Modify: `demonlock/Sources/DemonlockCore/ReleaseValve.swift:161-179` (`flushSelfServeQueues`)
- Delete old `consume(_:enforcedUID:) -> Data?` from MarkerIO (last caller gone).
- Test: `demonlock/Tests/DemonlockCoreTests/SafeAppsQueueTests.swift`, extend `DelayQueueTests` for flush.

**Interfaces:** `flushSelfServeQueues` becomes:

```swift
private static func flushSelfServeQueues() {
    let now = nowEpoch()
    for q in [Enforcer.policyQueue(), Enforcer.zonesQueue(), Enforcer.gatePolicyQueue(),
              SafeApps.queue(), SnoozePresets.invokeQueue(), SnoozePresets.addsQueue(),
              Lockbox.unlocksQueue()] { q.flushAll(now: now, reason: "admin grant") }
    Lockbox.relockAll()
}
```

- [ ] **Step 1:** Failing tests: safe-app same-name different `rootOwned` ⇒ replace+reset (the user's flag case); blocklisted bid rejected at queue AND landing; flush empties all seven queues + relocks windows + a pending invocation (assert each), one `flushed` event per queue.
- [ ] **Step 2:** FAIL → implement → PASS. Full suite green. Commit `feat: safe-apps on DelayQueue; grant flushes all queues + relocks`.

### Task 11: Status surface — final sweep (most work moved to Task 4.5 + per-port tasks)

**Files:**
- Modify: `demonlock/Sources/DemonlockCore/State.swift:51-57` (QStatus fields), `Enforcerd.swift:432-441` (publish), `Agent.swift:77-91` (`handleDelayedApplied`), `Commands.swift:61+` (`statusBody` delayed sections → `printQueueStatus` output), `runDelayZones`/`runDelaySetPolicy --status`/safe-apps `show`/snooze-preset `show`/lockbox `show` readers.

**Interfaces:**

```swift
// StateSnapshot replacements (names kept where possible):
var delayedPolicy: DelayQueue.QStatus? = nil
var delayedZones: DelayQueue.QStatus? = nil
var delayedGatePolicy: DelayQueue.QStatus? = nil
var safeApps: DelayQueue.QStatus? = nil
var snoozePresetInvoke: DelayQueue.QStatus? = nil
var snoozePresetAdds: DelayQueue.QStatus? = nil
var lockboxUnlocks: DelayQueue.QStatus? = nil
var lockbox: Lockbox.Status? = nil            // window/lock state only (kept)
// Agent: handleDelayedApplied(_ items: [(String, Double?)])  — (label, lastAppliedAt), same
// seeding/baseline logic, now fed from the seven QStatus fields.
```

- [ ] **Step 1:** Port; `statusBody` prints each queue section via `printQueueStatus` with its abort command string. Old `SafeApps.Status`/`SnoozePresets.Status` types + their tick return values deleted; ticks return `QStatus` (adjust Enforcer stash properties).
- [ ] **Step 2:** Compile-level + `swift test` green (status rendering covered by one snapshot-ish test: build a QStatus fixture, assert `printQueueStatus` output contains key, "lands", abort command, "last landed"). Commit `feat: status/agent surface on QStatus`.

### Task 12: Sidecar vendor + port

**Files:**
- Create: `nextdns-sidecar/Sources/nextdns-sidecar/DelayQueue.swift` (verbatim copy + header `// VENDORED from demonlock/Sources/DemonlockCore/DelayQueue.swift — edit there, copy here.` — strip the `import`-free file compiles standalone; any future `.retry` apply must be idempotent, header states it)
- Modify: `nextdns-sidecar/Sources/nextdns-sidecar/MarkerIO.swift` (sync to demonlock's new MarkerIO, same header)
- Modify: `nextdns-sidecar/Sources/nextdns-sidecar/Daemon.swift` (Registry → `DelayQueue`: kind "delay-add", store `.file(Paths.pendingFile, legacyDecode: Legacy.keyOnlyMap())` — copy the `Legacy.keyOnlyMap` + needed helpers into the vendored file; markers mDelayAdd/mAbort; `.retry`; payloadIsJSON: false; key = validated domain; apply = NextDNS allowlist add)
- Test: sidecar has no test target — add one mirroring Task 1 (lib `SidecarCore` split) **only if** the split is mechanical; otherwise rely on DemonlockCore's DelayQueue tests (identical file) + build. Decision recorded: rely on identical-file guarantee — add `demonlock/Tests/DemonlockCoreTests/VendorSyncTests.swift`: `testSidecarDelayQueueByteIdentical` (reads both files relative to `#filePath`, asserts equal minus header lines).

- [ ] **Step 1:** Copy files, port Daemon (`processMarkers` delay-add/abort sections replaced by one `tick` call with `applyBatch` wrapping the per-domain API call; arm/block markers stay bespoke via `consumeLast`; multi-domain CLI `delay-add a.com b.com` appends one line per domain).
- [ ] **Step 2:** `swift build` in `nextdns-sidecar/` on Mac; VendorSyncTests green. Commit `feat(sidecar): delay-add on vendored DelayQueue`.

### Task 13: Verification gate (pre-install)

- [ ] Full `swift test` on Mac — every test green; paste summary into the task log.
- [ ] `swift build -c release` both packages.
- [ ] **Ponytail over-engineering review** of `git diff main...delayqueue` (ponytail:ponytail-review); apply deletions it finds; suite stays green.
- [ ] Live smoke WITHOUT install (no root): run the release binary's pure paths — `demonlock help`, `_policytest`; assert legacy state fixtures in a temp dir migrate via a scratch harness test already covered in Task 4.
- [ ] Spec coverage sweep: walk spec v4.4 section by section; check each requirement has a passing test or a named manual-check line in Task 14. Record the mapping table in the PR/commit message.

### Task 14: Gate-window install + live verification (USER PRESENT — blocked until Minh's next release-valve window)

- [ ] Before: `demonlock status` snapshot; note pending queues will be flushed by the grant (expected).
- [ ] Install demonlock (existing `install.sh` flow), relaunch agent; then sidecar install.
- [ ] Live checks: `demonlock status` (all queue sections render); queue `add:test-zone` from map → row appears with abort command → `delayzones --abort "add:test-zone"` cancels; `delayzones --abort` (bare) on empty queue prints cleanly; queue two ops → both rows; `sudo demonlock delayzones set-delay 12h` floor honored; audit log lines present; agent alert fires on a landed change only (optional: 12h wait or set-delay floor + overnight check); sidecar `delay-add example.com` row + abort. Re-queue the two real edits: `add:730 moreno`, `del:imbue office` (rollout step 2). Keep the old binary at `/Applications/Demonlock.app.bak` for instant rollback.

---

## Self-review (author-run, per writing-plans)

- Spec coverage: every spec section mapped — Census (Tasks 5,6,8,9,10,12), Abstraction semantics (3), Marker contract (2), Boundary layer (2, 7), knobs (3,8), Zones (6,7), Cross-queue (6), Restart (3,9), Migration (4,8,9,12), bespoke list (8,9 keep-out respected), Testing (each bullet has a named test above), Rollout (13,14 + gate note).
- Known deviation recorded: `enqueueTransform` knob added (Task 8) beyond the spec's closed knob set — required to freeze invoke's `targetAt` at queue time. Alternative considered and REJECTED: CLI-computed targetAt would let a hand-written marker choose an arbitrary stand-down target (preset-spec-only is the current, stricter semantics; queue-time recompute-and-compare is clock-fragile). The daemon-side transform is the smallest compliant design. Spec's closed-knob sentence should gain this knob at next spec touch.
- Pass-3 (self) finding folded: Task 4.5 added — without it, Tasks 6-10 could not compile (DelayedStatus consumers). Joint-projection staleness note: zones' `peekDue` runs before policy/gate consume THIS tick's markers — safe for requests (a request consumed this tick gets applyAt=now+delay, never due now) but an abort consumed this tick could arrive after zones already deferred to a doc being aborted. Fail-closed (batch dropped, re-queue) and rare; if either adversary confirms it matters, fix = consume phase for all queues before any apply phase.
- Type consistency: `QStatus` field names in Task 11 match Task 3; `Legacy.*` signatures match Task 4 consumers in 5/12.
