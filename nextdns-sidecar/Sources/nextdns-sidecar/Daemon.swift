import Foundation

/// The delay-add DelayQueue (vendored abstraction): domain-keyed, idempotent re-request, .retry
/// with backoff on API failure (a failed allow keeps the domain blocked — retrying is safe/idempotent).
/// NOTE: the pending cap drops 4096 → DelayQueue.cap (64) — spec-mandated; >64 pending is unrealistic.
func delayAddQueue() -> DelayQueue {
    DelayQueue(kind: "delay-add",
               store: .file(Paths.pendingFile, legacyDecode: Legacy.keyOnlyMap()),
               requestMarker: Paths.mDelayAdd, abortMarker: Paths.mAbort,
               onFailure: .retry, payloadIsJSON: false,
               auditLog: Paths.supportDir + "/queue-audit.log")
}

/// The merged root enforcer — one daemon does BOTH jobs the two source tools split across two daemons:
///   • each tick asserts the pf ruleset + captive door + fail-closed profile check (from nextdns-lockdownd)
///   • processes user markers and applies due delayed allows (from the nextdns-delay-allow applier)
/// No timers — all state on disk, driven by the tick. Single-threaded (dropped the route-monitor watcher;
/// the 5s poll maintains the captive door, and the watcher was explicitly "pure bonus" in the original).
final class Daemon {
    private var pstate = ""                              // last profile state, to log transitions only
    static let interval = 5.0

    func run() {
        if geteuid() != 0 { logLine("WARNING: not running as root — enforcement and API calls will fail") }
        logLine("nextdns-sidecar enforcerd started (interval=\(Int(Daemon.interval))s)")
        while true {
            autoreleasepool { tick() }
            Thread.sleep(forTimeInterval: Daemon.interval)
        }
    }

    private func tick() {
        let now = nowEpoch()
        let cfg = Config.load()
        let euid = cfg.enforcedUID()

        // Markers + delayed applies run BEFORE enforcement and regardless of arm state (a scheduled
        // allow lands on time no matter what). The queue consumes abort before requests internally.
        processMarkers(now: now, euid: euid)
        runDelayQueue(now: now, euid: euid, delay: cfg.clampedDelay)

        // Publish BEFORE the marker phase too: processMarkers can run for minutes on a bulk block, and
        // a snapshot only written at tick end would age past stateStaleAfter and read as a dead daemon.
        Lockdown.publishState(armed: isArmedFlag())

        let armed = isArmedFlag()
        if armed {
            Lockdown.assertPF()
            pstate = Lockdown.assertProfile(prev: pstate)
        } else {
            Lockdown.restorePF()
        }
        // AFTER enforcing, so the snapshot describes this tick's outcome rather than the last one.
        Lockdown.publishState(armed: armed)
    }

    /// Consume the four inbox markers (owner-checked via MarkerIO). No enforced uid (fresh install) ⇒
    /// nothing to trust ⇒ skip; the time-based apply still runs.
    private func processMarkers(now: Double, euid: uid_t?) {
        guard let euid = euid else { return }

        // arm (tightening, no sudo): create the root-owned armed flag — but only if the DoH profile is
        // installed (arming with no resolver would be a total DNS outage). Re-checks the CLI's guard.
        if MarkerIO.consumeFlag(Paths.mArm, enforcedUID: euid) {
            if Lockdown.profilePresent() {
                FileManager.default.createFile(atPath: Paths.armedFile, contents: Data())
                logLine("ARMED (user request) — enforcement asserts this tick")
            } else {
                logLine("arm refused — Encrypted-DNS profile not installed")
            }
        }

        // block (immediate tighten, no sudo): call the API now. A consumed marker isn't retried across
        // ticks, but callRetry already retries transient failures 4× within the call.
        if let lines = MarkerIO.consumeLines(Paths.mBlock, enforcedUID: euid) {
            let doms = dedupCap(Data(lines.joined(separator: "\n").utf8))
            if !doms.isEmpty, let api = NextDNSAPI.load() {
                for d in doms {
                    let r = api.block(d)
                    logLine("block \(d) denylist+=\(r.add) allowlist-=\(r.rm) \(r.ok ? "OK" : "FAILED")")
                }
            } else if !doms.isEmpty {
                logLine("block requested for \(doms.count) domain(s) but credentials unavailable")
            }
        }

    }

    static let maxDomainsPerTick = 256   // per-tick synchronous-API cap (block + delayed-apply)

    /// Dedup + cap the domains from a marker so a giant/crafted marker can't wedge the single-threaded
    /// tick on synchronous curl (a no-sudo DoS). Order-preserving.
    private func dedupCap(_ data: Data) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for d in parseDomains(data).filter(validDomain) where seen.insert(d).inserted {
            out.append(d); if out.count >= Daemon.maxDomainsPerTick { break }
        }
        return out
    }

    /// One queue turn: consume markers (abort → requests, daemon-stamped clocks), then apply due
    /// allows via the API. .retry semantics: a failed call keeps the row (exponential backoff to
    /// 5 min) — fail-closed on loosening, the domain stays blocked until the allow actually sticks.
    private func runDelayQueue(now: Double, euid: uid_t?, delay: Double) {
        let q = delayAddQueue()
        q.consumeMarkers(now: now, enforcedUID: euid,
                         delaySec: { _ in delay },
                         key: { validDomain($0) ? $0 : nil },
                         validate: validDomain)
        _ = q.applyDue(now: now, validate: validDomain) { due in
            guard let api = NextDNSAPI.load() else {
                // EXPLICIT failure verdicts: a missing verdict means "deferred untouched" (per-tick
                // cap), which would leave broken credentials looking like healthy pending rows
                // forever — no backoff, no `failed` outcome, unthrottled log. False verdicts back
                // off and surface `failed` after the threshold.
                return Dictionary(uniqueKeysWithValues: due.map { ($0.key, (false, String?.some("credentials unavailable"))) })
            }
            var out: [String: (ok: Bool, reason: String?)] = [:]
            for (i, d) in due.enumerated() {
                guard i < Daemon.maxDomainsPerTick else { break }   // per-tick API cap; rest retry
                let r = api.allow(d.payload)
                out[d.key] = (r.ok, r.ok ? nil : "allowlist+=\(r.add) failed")
                logLine("delay-add \(r.ok ? "APPLIED" : "FAILED") \(d.payload) allowlist+=\(r.add)")
            }
            return out
        }
    }
}
