import Foundation

/// The RELEASE VALVE — a self-serve, delay-gated admin grant. You `--request` (no sudo); the daemon
/// stamps the request time itself, waits out `delaySec`, then grants admin (via `sudome
/// --give-to-user`) the first tick the WINDOW POLICY is provably true, for `durationSec`, then revokes
/// (`--take-from-user`). No timers — all state is on disk and driven by the enforcer tick.
///
/// Split of trust: config + lifecycle state are root-owned; only `--set-*` and the daemon write them.
/// `--request`/`abort` are non-root — they drop a marker in a user-owned inbox, and the daemon
/// stamps the real request time, so the delay can't be backdated.

// MARK: - Config (root-owned; all three required before --request works)

struct ReleaseValveConfig: Codable {
    var windowPolicy: String?   // when a request may be granted (policy syntax + the IN_POLICY primitive)
    var delaySec: Double?       // how long after --request before it's eligible (anti-"request right before a window")
    var durationSec: Double?    // how long the grant lasts before auto-revoke

    var isComplete: Bool { windowPolicy != nil && delaySec != nil && durationSec != nil }

    static func load() -> ReleaseValveConfig {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: Paths.rvConfigFile)),
              let c = try? JSONDecoder().decode(ReleaseValveConfig.self, from: d) else { return ReleaseValveConfig() }
        return c
    }
    func save() throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: URL(fileURLWithPath: Paths.rvConfigFile), options: .atomic)
    }
}

// MARK: - Lifecycle state (root-owned). requestedAt == nil ⇒ idle.

struct ReleaseValveState: Codable {
    var requestedAt: Double?      // when the daemon accepted the request (its clock — not backdatable)
    var eligibleAt: Double?       // requestedAt + delay (frozen at request time)
    var grantedAt: Double?        // when granted (nil until granted)
    var grantExpiresAt: Double?   // grantedAt + duration

    var isIdle: Bool { requestedAt == nil }
    var isGranted: Bool { grantedAt != nil }

    static func load() -> ReleaseValveState {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: Paths.rvStateFile)),
              let s = try? JSONDecoder().decode(ReleaseValveState.self, from: d) else { return ReleaseValveState() }
        return s
    }
    static func write(_ s: ReleaseValveState) {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        if let d = try? e.encode(s) { try? d.write(to: URL(fileURLWithPath: Paths.rvStateFile), options: .atomic) }
    }
}

// MARK: - Published status (status CLI + agent UI + notifications)

struct RVStatus: Codable {
    var configured: Bool
    var phase: String            // idle | delay | waiting | granted
    var requestedAtEpoch: Double?
    var eligibleAtEpoch: Double?
    var grantExpiresEpoch: Double?
    var windowPolicy: String?
    var windowTree: EvalNode?    // the window-policy evaluation (incl. IN_POLICY)
    var delaySec: Double?
    var durationSec: Double?
}

// MARK: - Tick (called once per enforcer tick, in the main-evaluation path)

enum ReleaseValve {
    /// Drive the valve one tick: consume markers, evaluate the window policy (IN_POLICY = `mainResult`),
    /// advance the lifecycle, run sudome give/take, and return the status to publish. `username` is the
    /// account to grant/revoke (resolved by the enforcer). `baseInputs` are the same policy inputs used
    /// for the main evaluation (fix/bssids/zones) — we just add IN_POLICY.
    static func tick(now: Date, mainResult: Tri, baseInputs: PolicyInputs, username: String?) -> RVStatus {
        let cfg = ReleaseValveConfig.load()
        var st = ReleaseValveState.load()
        let nowSec = now.timeIntervalSince1970
        let fm = FileManager.default

        // 1. Markers (non-root, user-dropped). Abort first, then request.
        if fm.fileExists(atPath: Paths.rvAbortMarker) {
            try? fm.removeItem(atPath: Paths.rvAbortMarker)
            if st.isGranted, let u = username { revoke(u) }   // abort closes a live grant immediately
            st = ReleaseValveState(); ReleaseValveState.write(st)
        }
        if fm.fileExists(atPath: Paths.rvRequestMarker) {
            try? fm.removeItem(atPath: Paths.rvRequestMarker)
            if cfg.isComplete && st.isIdle {
                st.requestedAt = nowSec
                st.eligibleAt = nowSec + (cfg.delaySec ?? 0)   // freeze eligibility at request time
                ReleaseValveState.write(st)
                log("release-valve: request accepted (eligible in \(Int(cfg.delaySec ?? 0))s)")
            }
            // else: not fully configured, or a request is already active → ignore this marker
        }

        // 2. Evaluate the window policy with IN_POLICY = the main verdict.
        var windowTree: EvalNode?
        var windowTri: Tri = .unknown
        if let wp = cfg.windowPolicy, let policy = try? PolicyEngine.parse(wp) {
            var inp = baseInputs; inp.inPolicy = mainResult
            let (r, t) = PolicyEngine.evaluate(policy, inp)
            windowTri = r; windowTree = t
        }

        // 3. Lifecycle: expire a live grant; or grant a pending request once eligible AND in-window.
        if st.isGranted {
            if nowSec >= (st.grantExpiresAt ?? 0), let u = username {
                revoke(u)
                st = ReleaseValveState(); ReleaseValveState.write(st)
            }
        } else if !st.isIdle {
            if nowSec >= (st.eligibleAt ?? .infinity), windowTri == .t, let u = username {
                grant(u)
                st.grantedAt = nowSec
                st.grantExpiresAt = nowSec + (cfg.durationSec ?? 0)
                ReleaseValveState.write(st)
            }
        }

        // 4. Status.
        let phase: String
        if st.isGranted { phase = "granted" }
        else if st.isIdle { phase = "idle" }
        else { phase = nowSec < (st.eligibleAt ?? 0) ? "delay" : "waiting" }

        return RVStatus(configured: cfg.isComplete, phase: phase,
                        requestedAtEpoch: st.requestedAt, eligibleAtEpoch: st.eligibleAt,
                        grantExpiresEpoch: st.grantExpiresAt, windowPolicy: cfg.windowPolicy,
                        windowTree: windowTree, delaySec: cfg.delaySec, durationSec: cfg.durationSec)
    }

    private static func grant(_ user: String)  { log("release-valve: GRANT admin → \(user)");  Proc.run(Paths.sudomeBin, ["--give-to-user", user]) }
    private static func revoke(_ user: String) { log("release-valve: REVOKE admin ← \(user)"); Proc.run(Paths.sudomeBin, ["--take-from-user", user]) }

    private static func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        FileHandle.standardError.write(Data("[\(f.string(from: Date()))] \(s)\n".utf8))
    }
}
