import Foundation

/// A DELAYED CHANGE — a non-sudo self-serve edit that lands after a fixed delay. You queue a new
/// policy (`demonlock delaysetpolicy`) or a new zones set (the map's "Save in 36h" button); the daemon
/// stamps the request time ITSELF, waits out the delay, then applies it. No timers — all state is on
/// disk and driven by the enforcer tick, and it applies regardless of arm / snooze / who's logged in
/// (it's a scheduled config change, not enforcement).
///
/// Same split of trust as the release valve: the pending record is root-owned; the request/abort
/// markers are non-root (dropped in the user-owned inbox), and the daemon stamps the real request
/// time — so the delay can't be backdated. The 36h wait IS the commitment device: impulse-you can
/// queue a loosening, but only calm-you-36h-from-now actually gets it.

// Pending queued change (root-owned). Absent ⇒ nothing queued.
struct PendingChange: Codable {
    var payload: String       // the full new policy text / zones.json to install when it lands
    var requestedAt: Double   // daemon clock at acceptance (not backdatable)
    var applyAt: Double       // requestedAt + delay (frozen at request time)
}

// Persisted slot: the pending change + when one last landed (drives the "applied" notification, which
// must survive daemon restarts and the agent's faster poll, so it lives on disk not in memory).
struct DelayedState: Codable {
    var pending: PendingChange?
    var lastAppliedAt: Double?

    static func load(_ path: String) -> DelayedState { loadJSON(path) ?? DelayedState() }
    func save(_ path: String) { saveJSON(self, to: path) }
}

// Published status (status CLI + agent UI + the applied-notification).
struct DelayedStatus: Codable {
    var kind: String              // "policy" | "zones"
    var pending: Bool
    var applyAtEpoch: Double?
    var payloadPreview: String?
    var lastAppliedEpoch: Double?
}

enum DelayedChange {
    static let policyDelaySec: Double = 36 * 3600
    static let zonesDelaySec:  Double = 36 * 3600

    /// Drive one delayed-change slot for a single tick: consume its markers (abort first, then
    /// request), then apply a pending change once its time has arrived. `validate` gates a queued
    /// payload at BOTH queue time and apply time (zones/policy could have changed under it); `apply`
    /// installs it and returns whether it stuck. Returns the status to publish.
    static func tick(kind: String, now: Double, stateFile: String,
                     requestMarker: String, abortMarker: String, delaySec: Double,
                     enforcedUID: uid_t?, validate: (String) -> Bool, apply: (String) -> Bool) -> DelayedStatus {
        var st = DelayedState.load(stateFile)

        // Markers are consumed through MarkerIO (O_NOFOLLOW + owner==enforcedUID + unlink-verify), so a
        // symlink/hardlink in the user-owned inbox can't turn the root daemon into a read primitive, and
        // a `chflags uchg` marker that can't be removed doesn't re-fire. No enforced user yet (fresh
        // install) → no markers to trust → skip; the time-based apply below still runs.
        if let euid = enforcedUID {
            // 1. abort marker → drop whatever's queued.
            if MarkerIO.consumeFlag(abortMarker, enforcedUID: euid), st.pending != nil {
                st.pending = nil; st.save(stateFile)
            }
            // 2. request marker (contents = payload) → validate + (re)queue, resetting the delay. A repeat
            //    request just pushes the landing further out (stricter), so it can't be used to shorten it.
            if let data = MarkerIO.consume(requestMarker, enforcedUID: euid) {
                let p = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !p.isEmpty, validate(p) {
                    st.pending = PendingChange(payload: p, requestedAt: now, applyAt: now + delaySec)
                    st.save(stateFile)
                    logStderr("delayed-\(kind): queued — applies in \(Int(delaySec/3600))h")
                } else {
                    logStderr("delayed-\(kind): rejected an invalid queued change")
                }
            }
        }
        // 3. apply when due (re-validate; a stale/invalid payload is dropped, fail-closed).
        if let pc = st.pending, now >= pc.applyAt {
            if validate(pc.payload), apply(pc.payload) { st.lastAppliedAt = now; logStderr("delayed-\(kind): APPLIED") }
            else { logStderr("delayed-\(kind): apply FAILED — dropped the queued change") }
            st.pending = nil; st.save(stateFile)
        }

        return DelayedStatus(kind: kind, pending: st.pending != nil, applyAtEpoch: st.pending?.applyAt,
                             payloadPreview: st.pending.map { preview($0.payload) },
                             lastAppliedEpoch: st.lastAppliedAt)
    }

    private static func preview(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > 90 ? String(one.prefix(87)) + "…" : one
    }
}
