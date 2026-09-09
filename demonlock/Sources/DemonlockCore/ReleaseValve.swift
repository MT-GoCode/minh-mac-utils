import Foundation

/// The ADMIN RELEASE VALVE — a self-serve, delay-gated admin grant. You `request "<duration>"` (no
/// sudo); the daemon stamps the request time itself, waits out `delaySec`, then — the first tick the
/// GATE POLICY is provably true — grants admin (Admin.grant) for your requested duration, then revokes
/// (Admin.revoke). No timers: all state on disk, driven by the enforcer tick.
///
/// Three config fields (root-owned, set via sudo): gatePolicy (WHEN a grant may open — policy syntax +
/// the IN_POLICY primitive), delaySec (wait after request before eligible — clamped ≥ Bounds floor),
/// maxRequestDurationSec (ceiling on the requested grant length — clamped ≤ Bounds ceiling).
///
/// Trust split: config + lifecycle state are root-owned; `request`/`abort` are non-root markers in the
/// user-owned inbox, consumed via MarkerIO (owner-checked, symlink/hardlink-proof). `i-still-need-sudo`
/// is a SUDO command (you only hold admin during a live grant, so it can only EXTEND one, never
/// bootstrap one) and writes state directly as root. The REQUEST DELAY is the real commitment gate; the
/// auto-revoke is anti-accident, not containment (see Admin). [reviews M1, M2, H5]

// MARK: - Config (root-owned)

struct ReleaseValveConfig: Codable {
    var gatePolicy: String?             // when a request may be granted (policy syntax + IN_POLICY)
    var delaySec: Double?               // wait after request before eligible (anti "request right before a window")
    var maxRequestDurationSec: Double?  // ceiling on the duration a request may ask for

    var isComplete: Bool { gatePolicy != nil && delaySec != nil && maxRequestDurationSec != nil }

    /// Effective (Bounds-clamped) values, so a stale file or a settings edit can't push below a floor.
    var effectiveDelay: Double { Bounds.clamp(delaySec ?? Bounds.rvRequestDelayMin, Bounds.rvRequestDelayMin ... .greatestFiniteMagnitude) }
    var effectiveMaxDuration: Double { min(maxRequestDurationSec ?? Bounds.rvMaxRequestDurationCeil, Bounds.rvMaxRequestDurationCeil) }

    static func load() -> ReleaseValveConfig { loadJSON(Paths.rvConfigFile) ?? ReleaseValveConfig() }
    func save() throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: URL(fileURLWithPath: Paths.rvConfigFile), options: .atomic)
    }
}

// MARK: - Lifecycle state (root-owned). requestedAt == nil ⇒ idle.

struct ReleaseValveState: Codable {
    var requestedAt: Double?          // when the daemon accepted the request (its clock — not backdatable)
    var eligibleAt: Double?           // requestedAt + delay (frozen at request time)
    var requestedDurationSec: Double? // grant length the request asked for (clamped to the config ceiling)
    var grantedAt: Double?            // when granted (nil until granted)
    var grantExpiresAt: Double?       // grantedAt + duration (extendable by i-still-need-sudo)

    var isIdle: Bool { requestedAt == nil }
    var isGranted: Bool { grantedAt != nil }

    static func load() -> ReleaseValveState { loadJSON(Paths.rvStateFile) ?? ReleaseValveState() }
    static func write(_ s: ReleaseValveState) { saveJSON(s, to: Paths.rvStateFile) }
}

// MARK: - Published status (status CLI + agent UI + notifications)

struct RVStatus: Codable {
    var configured: Bool
    var phase: String            // idle | delay | waiting | granted
    var requestedAtEpoch: Double?
    var eligibleAtEpoch: Double?
    var grantExpiresEpoch: Double?
    var requestedDurationSec: Double?
    var gatePolicy: String?
    var windowTree: EvalNode?    // the gate-policy evaluation (incl. IN_POLICY)
    var windowOpen: Bool         // gate currently true — shown in status while a request waits to grant
    var delaySec: Double?
    var maxRequestDurationSec: Double?
}

// MARK: - Tick (called once per enforcer tick, in the main-evaluation path)

enum ReleaseValve {
    /// Drive the valve one tick: consume markers, evaluate the gate (IN_POLICY = `mainResult`), advance
    /// the lifecycle, run Admin grant/revoke, return the status to publish. `username` is the account to
    /// grant/revoke; `enforcedUID` owner-checks the user markers.
    static func tick(now: Date, mainResult: Tri, baseInputs: PolicyInputs,
                     username: String?, enforcedUID: uid_t?) -> RVStatus {
        let cfg = ReleaseValveConfig.load()
        var st = ReleaseValveState.load()
        let nowSec = now.timeIntervalSince1970

        // 1. Markers (non-root, user-dropped, MarkerIO-hardened). Abort first, then request.
        if let euid = enforcedUID {
            if MarkerIO.consumeFlag(Paths.rvAbortMarker, enforcedUID: euid) {
                if st.isGranted, let u = username { _ = Admin.revoke(u) }   // abort closes a live grant now
                st = ReleaseValveState(); ReleaseValveState.write(st)
            }
            if let data = MarkerIO.consume(Paths.rvRequestMarker, enforcedUID: euid) {
                let durText = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let asked = TimeSpec.parseDuration(durText) ?? 0
                let dur = min(max(asked, 0), cfg.effectiveMaxDuration)
                if cfg.isComplete, dur > 0 {
                    if st.isIdle {
                        st.requestedAt = nowSec
                        st.eligibleAt = nowSec + cfg.effectiveDelay   // freeze eligibility at request time
                        st.requestedDurationSec = dur
                        ReleaseValveState.write(st)
                        logStderr("release-valve: request accepted (\(Int(dur/60))m grant, eligible in \(Int(cfg.effectiveDelay))s)")
                    } else if !st.isGranted {
                        // Idempotent: a repeat request while PENDING only updates the duration; it does NOT
                        // reset eligibleAt (can't shorten OR extend the delay).
                        st.requestedDurationSec = dur; ReleaseValveState.write(st)
                        logStderr("release-valve: pending request duration updated to \(Int(dur/60))m")
                    }
                    // granted → ignore (already have admin)
                }
            }
        }

        // 2. Evaluate the gate with IN_POLICY = the main verdict.
        var windowTree: EvalNode?
        var windowTri: Tri = .unknown
        if let wp = cfg.gatePolicy, let policy = try? PolicyEngine.parse(wp) {
            var inp = baseInputs; inp.inPolicy = mainResult
            let (r, t) = PolicyEngine.evaluate(policy, inp)
            windowTri = r; windowTree = t
        }

        // 3. Lifecycle: expire a live grant; or grant a pending request once eligible AND gate-true.
        if st.isGranted {
            if nowSec >= (st.grantExpiresAt ?? 0), let u = username {
                _ = Admin.revoke(u)
                st = ReleaseValveState(); ReleaseValveState.write(st)
            }
        } else if !st.isIdle {
            // Re-read rv-state immediately before granting: `arm`/`nosudo` (hardReset, a separate process)
            // may have CLOSED the valve since we loaded `st` at the top of the tick. Without this re-check
            // the grant could land after a reset → admin held while armed (violates M2: arm closes the
            // valve). Narrows the lock-free window to microseconds; a full flock would close it entirely.
            if nowSec >= (st.eligibleAt ?? .infinity), windowTri == .t, let u = username,
               !ReleaseValveState.load().isIdle {
                _ = Admin.grant(u)
                flushSelfServeQueues()
                st.grantedAt = nowSec
                st.grantExpiresAt = nowSec + (st.requestedDurationSec ?? 0)
                ReleaseValveState.write(st)
                logStderr("release-valve: GRANT admin → \(u) for \(Int((st.requestedDurationSec ?? 0)/60))m")
            }
        }

        // 4. Status.
        let phase: String
        if st.isGranted { phase = "granted" }
        else if st.isIdle { phase = "idle" }
        else { phase = nowSec < (st.eligibleAt ?? 0) ? "delay" : "waiting" }

        return RVStatus(configured: cfg.isComplete, phase: phase,
                        requestedAtEpoch: st.requestedAt, eligibleAtEpoch: st.eligibleAt,
                        grantExpiresEpoch: st.grantExpiresAt, requestedDurationSec: st.requestedDurationSec,
                        gatePolicy: cfg.gatePolicy, windowTree: windowTree, windowOpen: windowTri == .t,
                        delaySec: cfg.effectiveDelay, maxRequestDurationSec: cfg.effectiveMaxDuration)
    }

    /// On a fresh admin GRANT, cancel every no-sudo self-serve QUEUE plus any open lockbox window: the
    /// delayed policy / zones / release-valve-gate-policy changes, pending safe-app registrations, pending
    /// snooze-preset adds, and the lockbox (pending unlocks AND currently-unlocked secrets). Those are the
    /// commitment-device paths you use WITHOUT admin; once you hold admin you make changes deliberately
    /// with sudo, so nothing queued should silently land later. Already-applied config and registered
    /// spares are untouched, and an in-flight snooze (active suppression) is left alone — it's not a queue.
    private static func flushSelfServeQueues() {
        var cleared: [String] = []
        func flushDelayed(_ path: String, _ label: String) {
            var s = DelayedState.load(path)
            if s.pending != nil { s.pending = nil; s.save(path); cleared.append(label) }
        }
        flushDelayed(Paths.delayedPolicyFile, "delay-set-policy")
        flushDelayed(Paths.delayedZonesFile, "delayzones")
        flushDelayed(Paths.delayedGatePolicyFile, "delay-set-gate-policy")
        var sa = SafeApps.Registry.load()
        if !sa.pending.isEmpty { sa.pending.removeAll(); sa.save(); cleared.append("safe-apps") }
        var sp = SnoozePresets.SPState.load()
        if !sp.adds.isEmpty { sp.adds.removeAll(); sp.save(); cleared.append("snooze-preset-adds") }
        var lb = Lockbox.LBState.load()
        if !lb.pending.isEmpty || !lb.unlockedUntil.isEmpty {
            lb.pending.removeAll(); lb.unlockedUntil.removeAll(); lb.save(); cleared.append("lockbox")
        }
        if !cleared.isEmpty { logStderr("release-valve: grant flushed queued self-serve changes: \(cleared.joined(separator: ", "))") }
    }

    /// Revoke any live grant and clear all state. Called by `arm` and `nosudo` (both root). Idempotent.
    /// [review M2 — arm must close the valve, else a pending/granted request hands out admin after arming]
    static func hardReset(username: String?) {
        let st = ReleaseValveState.load()
        if st.isGranted, let u = username { _ = Admin.revoke(u) }
        ReleaseValveState.write(ReleaseValveState())
    }
}
