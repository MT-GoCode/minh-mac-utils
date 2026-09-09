import Foundation

/// ONE abstraction for every commitment-delayed change (spec: docs/specs/2026-09-09-delayqueue-design.md).
/// A keyed, root-owned pending registry with daemon-stamped clocks. Multi-item; seq-ordered landing;
/// idempotent same-payload requeue; replace+reset on different payload; abort by key / --all /
/// zero-byte file; validate at queue AND landing (fail-closed); save-before-apply crash safety for
/// `.drop`; retry-with-backoff for `.retry`; full audit trail. Per-surface key/validate/apply logic
/// stays in app closures — the queue never knows what a zone is.
///
/// Self-containment contract (this file vendors byte-identical into nextdns-sidecar): Foundation
/// plus exactly four free symbols — `loadJSON`, `saveJSON`, `logStderr`, `nowEpoch` — and
/// `MarkerIO.consumeLines`. No `Paths.*` (the audit path arrives via `auditLog`). Any future
/// `.retry` apply must be idempotent (a crash between apply-success and save re-applies once).
struct DelayQueue {
    struct Item: Codable, Equatable {
        var payload: String
        var requestedAt: Double
        var applyAt: Double
        var seq: UInt64
        var retries: UInt32? = nil        // .retry bookkeeping (optional ⇒ decodeIfPresent — a
        var nextRetryAt: Double? = nil    //  non-optional default would THROW on older JSON and
                                          //  silently empty the queue; nil means 0)
    }
    struct Outcome: Codable, Equatable {
        var key: String                   // batch/flush events: the affected keys joined ", "
        var what: String                  // queued|replaced|aborted|applying|applied|rejected|failed|unconfirmed|flushed
        var reason: String?
        var at: Double
    }
    struct QState: Codable {
        var pending: [String: Item] = [:]
        var nextSeq: UInt64 = 0
        var lastAppliedAt: Double? = nil
        var recent: [Outcome] = []        // last 8 EVENTS, newest first (batch/flush = one event)
    }
    struct Row: Codable { var key: String; var preview: String; var applyAt: Double; var seq: UInt64 }
    struct QStatus: Codable {
        var kind: String
        var rows: [Row] = []              // seq order
        var lastAppliedAt: Double? = nil
        var recent: [Outcome] = []
        var full: Bool = false
    }

    /// The state-persistence seam: a plain file, or a named sub-object of a composite file
    /// (snooze-presets.json holds two queues + siblings; lockbox-state.json holds unlockedUntil).
    struct QStateStore {
        let load: () -> QState
        let save: (QState) -> Void

        /// Plain-file store. On a QState decode failure, tries `legacyDecode` (per-surface shape),
        /// then falls back to empty (fail-closed, like loadJSON everywhere else). After any load,
        /// nextSeq is forced strictly above every pending seq — migration must never re-create the
        /// ordering ties seq exists to kill.
        static func file(_ path: String,
                         legacyDecode: ((Data) -> (rows: [String: Item], lastAppliedAt: Double?)?)? = nil) -> QStateStore {
            QStateStore(
                load: {
                    var st: QState
                    if let s: QState = loadJSON(path) { st = s }
                    else if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                            let legacy = legacyDecode?(data) {
                        st = QState(pending: legacy.rows, nextSeq: 0, lastAppliedAt: legacy.lastAppliedAt, recent: [])
                        logStderr("delay-\(path): migrated legacy state (\(legacy.rows.count) pending)")
                    } else { st = QState() }
                    let maxSeq = st.pending.values.map(\.seq).max()
                    if let m = maxSeq, st.nextSeq <= m { st.nextSeq = m + 1 }
                    return st
                },
                save: { saveJSON($0, to: path) })
        }
    }

    enum Failure { case drop, retry }

    let kind: String
    let store: QStateStore
    let requestMarker: String
    let abortMarker: String
    let onFailure: Failure
    let payloadIsJSON: Bool               // canonicalisation mode — declared, never sniffed
    let auditLog: String

    static let cap = 64
    static let clockSlackSec = 300.0
    static let retryBackoffCeilSec = 300.0
    static let retryFailedOutcomeAfter: UInt32 = 10

    // MARK: - canonicalisation (identity comparison for the requeue rule)

    /// JSON queues re-encode sorted-keys/unpretty (a UI pretty-print and a CLI compact form of the
    /// same value are identical); decode failure falls back to trimmed bytes. Non-JSON queues
    /// (policy expressions, bare names) compare as trimmed UTF-8 bytes.
    func canonical(_ payload: String) -> String {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard payloadIsJSON,
              let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return trimmed }
        return s
    }

    // MARK: - PHASE 1: consume markers

    /// Crash sweep (step 0) → abort → requests → clock guard. Returns the keys aborted by THIS
    /// call so app code can mirror side effects (lockbox relocks an aborted name's open window) —
    /// the 8-event `recent` ring is never the transport for that.
    @discardableResult
    func consumeMarkers(now: Double, enforcedUID: uid_t?,
                        delaySec: (String) -> Double,
                        key: (String) -> String?,
                        validate: (String) -> Bool) -> [String] {
        var st = store.load()
        var dirty = false
        var abortedKeys: [String] = []

        // 0. Crash sweep — unconditional: an `applying` outcome surviving from a previous tick means
        // a crash hit the save-before-apply window; the row is gone (fail-closed), and the audit must
        // say what is actually known: unconfirmed — may or may not have landed; never re-applied.
        for i in st.recent.indices where st.recent[i].what == "applying" {
            st.recent[i].what = "unconfirmed"
            st.recent[i].reason = "may or may not have landed; not re-applied (crash window)"
            audit(st.recent[i]); dirty = true
        }

        if let euid = enforcedUID {
            // 1. Abort — consumed BEFORE requests (abort+requeue in one tick stays clean, as today).
            if let lines = MarkerIO.consumeLines(abortMarker, enforcedUID: euid) {
                let keys = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if lines.isEmpty || keys.contains("--all") {
                    // Zero-byte FILE or a literal --all line ⇒ abort everything (both shipped CLI shapes).
                    if !st.pending.isEmpty {
                        abortedKeys = st.pending.keys.sorted()
                        record(&st, Outcome(key: abortedKeys.joined(separator: ", "),
                                            what: "flushed", reason: "abort --all", at: now))
                        st.pending.removeAll()
                    }
                    dirty = true
                } else {
                    for k in keys where k != "--all" {
                        if st.pending.removeValue(forKey: k) != nil {
                            abortedKeys.append(k)
                            record(&st, Outcome(key: k, what: "aborted", reason: nil, at: now))
                        } else {
                            record(&st, Outcome(key: k, what: "rejected", reason: "no such pending key", at: now))
                        }
                    }
                    dirty = true
                }
            }

            // 2. Requests — file order; each line judged individually (a poison line never kills a batch).
            if let lines = MarkerIO.consumeLines(requestMarker, enforcedUID: euid) {
                for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let k = key(line) else {
                        record(&st, Outcome(key: preview(line), what: "rejected", reason: "unkeyable", at: now)); continue
                    }
                    guard validate(line) else {
                        record(&st, Outcome(key: k, what: "rejected", reason: "invalid at queue", at: now)); continue
                    }
                    if let existing = st.pending[k] {
                        if canonical(existing.payload) == canonical(line) { continue }   // idempotent: clock kept
                        // Different payload ⇒ replace AND reset the clock (stricter — a mild pending
                        // request must not be swapped for an aggressive one at hour 35 and land at 36).
                        st.pending[k] = Item(payload: line, requestedAt: now, applyAt: now + delaySec(line), seq: st.nextSeq)
                        st.nextSeq += 1
                        record(&st, Outcome(key: k, what: "replaced", reason: "delay restarted", at: now))
                    } else if st.pending.count >= Self.cap {
                        // New keys only — replaces and aborts are always accepted at the cap.
                        record(&st, Outcome(key: k, what: "rejected", reason: "queue full (\(Self.cap)/\(Self.cap))", at: now))
                    } else {
                        st.pending[k] = Item(payload: line, requestedAt: now, applyAt: now + delaySec(line), seq: st.nextSeq)
                        st.nextSeq += 1
                        record(&st, Outcome(key: k, what: "queued", reason: nil, at: now))
                    }
                }
                dirty = true
            }
        }

        // 3. Clock guard — a backward jump > slack re-stamps (fail-closed: the wait restarts, never
        // shortens); the slack absorbs routine NTP boot steps. Forward jumps are indistinguishable
        // from a long shutdown and land normally.
        for (k, item) in st.pending where item.requestedAt > now + Self.clockSlackSec {
            var it = item
            it.requestedAt = now
            it.applyAt = now + (it.applyAt - item.requestedAt)   // preserve the original full delay span
            st.pending[k] = it
            logStderr("delay-\(kind): clock moved backward past \(k)'s request — re-stamped (full delay restarted)")
            dirty = true
        }

        if dirty { store.save(st) }
        return abortedKeys
    }

    // MARK: - PHASE 2: apply due rows

    /// Read-only view of what's due (seq order) — the cross-queue joint projection input.
    func peekDue(now: Double) -> [(key: String, payload: String)] {
        store.load().pending
            .filter { now >= $0.value.applyAt }
            .sorted { $0.value.seq < $1.value.seq }
            .map { ($0.key, $0.value.payload) }
    }

    /// Apply everything due, in seq order. `applyBatch` gets ALL due items at once (zones folds
    /// them); keys missing from its result are failed — fail-closed, never silently applied.
    func applyDue(now: Double,
                  validate: (String) -> Bool,
                  applyBatch: (_ due: [(key: String, payload: String, requestedAt: Double)]) -> [String: (ok: Bool, reason: String?)]) -> QStatus {
        var st = store.load()
        var dirty = false

        var due = st.pending
            .filter { now >= $0.value.applyAt }
            .filter { onFailure == .drop || now >= ($0.value.nextRetryAt ?? 0) }
            .sorted { $0.value.seq < $1.value.seq }

        // Re-validate at landing against live state; a stale/invalid payload is dropped, fail-closed.
        due = due.filter { (k, item) in
            if validate(item.payload) { return true }
            st.pending.removeValue(forKey: k)
            record(&st, Outcome(key: k, what: "rejected", reason: "invalid at landing", at: now))
            dirty = true
            return false
        }

        if !due.isEmpty {
            let tuples = due.map { ($0.key, $0.value.payload, $0.value.requestedAt) }
            let joined = due.map(\.key).joined(separator: ", ")
            switch onFailure {
            case .drop:
                // SAVE-BEFORE-APPLY: rows leave `pending` and the state hits disk BEFORE apply runs.
                // A crash in between loses the request (fail-closed) instead of re-applying a
                // loosening (a re-opened lockbox window on a secret at next boot, unrequested).
                for (k, _) in due { st.pending.removeValue(forKey: k) }
                record(&st, Outcome(key: joined, what: "applying", reason: nil, at: now))
                store.save(st)

                let results = applyBatch(tuples)
                let ok = due.map(\.key).filter { results[$0]?.ok == true }
                let failed = due.map(\.key).filter { results[$0]?.ok != true }

                // Rewrite the `applying` event to what actually happened (never leave it — and never
                // claim `applied` for a change that didn't land). lastAppliedAt bumps on success ONLY.
                st.recent.removeAll { $0.what == "applying" && $0.at == now }
                if !ok.isEmpty {
                    st.lastAppliedAt = now
                    record(&st, Outcome(key: ok.joined(separator: ", "), what: "applied", reason: nil, at: now))
                }
                if !failed.isEmpty {
                    let reasons = failed.compactMap { k in results[k]?.reason.map { "\(k): \($0)" } ?? k }
                    record(&st, Outcome(key: failed.joined(separator: ", "), what: "failed",
                                        reason: reasons.joined(separator: "; "), at: now))
                }
                store.save(st)
                dirty = false

            case .retry:
                // Remove-after-success — a crash between apply-success and save re-applies once,
                // safe only because .retry applies are contractually idempotent (set-like).
                let results = applyBatch(tuples)
                for (k, item) in due {
                    if results[k]?.ok == true {
                        st.pending.removeValue(forKey: k)
                        st.lastAppliedAt = now
                        record(&st, Outcome(key: k, what: "applied", reason: nil, at: now))
                    } else {
                        var it = item
                        let r = it.retries ?? 0
                        it.nextRetryAt = now + min(Self.retryBackoffCeilSec, 5 * pow(2, Double(r)))
                        it.retries = r + 1
                        st.pending[k] = it
                        if it.retries == Self.retryFailedOutcomeAfter {
                            record(&st, Outcome(key: k, what: "failed",
                                                reason: (results[k]?.reason ?? "apply failing") + " — still retrying", at: now))
                        }
                    }
                }
                store.save(st)
                dirty = false
            }
        }

        if dirty { store.save(st) }
        return status(st)
    }

    /// Single-queue convenience (sidecar): consume + apply with a per-item `apply`.
    @discardableResult
    func tick(now: Double, enforcedUID: uid_t?,
              delaySec: (String) -> Double,
              key: (String) -> String?,
              validate: (String) -> Bool,
              apply: (String) -> Bool) -> QStatus {
        _ = consumeMarkers(now: now, enforcedUID: enforcedUID, delaySec: delaySec, key: key, validate: validate)
        return applyDue(now: now, validate: validate,
                        applyBatch: { due in
                            Dictionary(uniqueKeysWithValues: due.map { ($0.key, (apply($0.payload), String?.none)) }) })
    }

    // MARK: - flush / status

    /// Discard ALL pending (admin-grant flush): with admin in hand you change things deliberately
    /// via sudo, so nothing queued should silently land later. One `flushed` event listing the keys.
    func flushAll(now: Double, reason: String) {
        var st = store.load()
        guard !st.pending.isEmpty else { return }
        let keys = st.pending.keys.sorted().joined(separator: ", ")
        st.pending.removeAll()
        record(&st, Outcome(key: keys, what: "flushed", reason: reason, at: now))
        store.save(st)
    }

    func status() -> QStatus { status(store.load()) }

    private func status(_ st: QState) -> QStatus {
        QStatus(kind: kind,
                rows: st.pending.sorted { $0.value.seq < $1.value.seq }
                    .map { Row(key: $0.key, preview: preview($0.value.payload),
                               applyAt: $0.value.applyAt, seq: $0.value.seq) },
                lastAppliedAt: st.lastAppliedAt,
                recent: st.recent,
                full: st.pending.count >= Self.cap)
    }

    // MARK: - outcomes + audit

    private func record(_ st: inout QState, _ o: Outcome) {
        st.recent.insert(o, at: 0)
        if st.recent.count > 8 { st.recent.removeLast(st.recent.count - 8) }
        audit(o)
    }

    /// One line per event to the append-only audit file — the history that didn't exist on Sep 7.
    private func audit(_ o: Outcome) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var line = "[\(f.string(from: Date(timeIntervalSince1970: o.at)))] \(kind) \(o.key) \(o.what.uppercased())"
        if let r = o.reason { line += " — \(r)" }
        let fd = open(auditLog, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        _ = (line + "\n").withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }

    private func preview(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > 90 ? String(one.prefix(87)) + "…" : one
    }
}
