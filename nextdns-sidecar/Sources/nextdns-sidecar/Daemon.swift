import Foundation

/// A queued delayed allow (root-owned). Absent key ⇒ nothing queued for that domain.
struct Pending: Codable { var requestedAt: Double; var applyAt: Double }

/// Domain-keyed pending registry — the delay-add queue. Keyed by domain so a repeat delay-add keeps the
/// ORIGINAL landing time (can't be used to shorten the wait), matching the C tool's dedupe.
struct Registry: Codable {
    var pending: [String: Pending] = [:]

    static func load() -> Registry {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: Paths.pendingFile)),
              let r = try? JSONDecoder().decode(Registry.self, from: d) else { return Registry() }
        return r
    }
    func save() {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        try? e.encode(self).write(to: URL(fileURLWithPath: Paths.pendingFile), options: .atomic)
    }
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
        // allow lands on time no matter what). abort is consumed before delay-add so abort+requeue in
        // one tick is clean (mirrors demonlock's order).
        processMarkers(now: now, euid: euid, delay: cfg.clampedDelay)
        applyDueAdds(now: now)

        if isArmedFlag() {
            Lockdown.assertPF()
            pstate = Lockdown.assertProfile(prev: pstate)
        } else {
            Lockdown.restorePF()
        }
    }

    /// Consume the four inbox markers (owner-checked via MarkerIO). No enforced uid (fresh install) ⇒
    /// nothing to trust ⇒ skip; the time-based apply still runs.
    private func processMarkers(now: Double, euid: uid_t?, delay: Double) {
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
        if let data = MarkerIO.consume(Paths.mBlock, enforcedUID: euid) {
            let doms = parseDomains(data).filter(validDomain)
            if !doms.isEmpty, let api = NextDNSAPI.load() {
                for d in doms {
                    let r = api.block(d)
                    logLine("block \(d) denylist+=\(r.add) allowlist-=\(r.rm) \(r.ok ? "OK" : "FAILED")")
                }
            } else if !doms.isEmpty {
                logLine("block requested for \(doms.count) domain(s) but credentials unavailable")
            }
        }

        // abort (tightening): drop pending delayed allows by domain, or "--all".
        if let data = MarkerIO.consume(Paths.mAbort, enforcedUID: euid) {
            var reg = Registry.load()
            let arg = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if arg.isEmpty || arg == "--all" { reg.pending.removeAll() }
            else { for d in parseDomains(data) { reg.pending.removeValue(forKey: d) } }
            reg.save()
            logLine("delay-add aborted (\(arg.isEmpty ? "--all" : arg))")
        }

        // delay-add (no sudo, lands after the delay): queue, stamping the daemon's own clock so the wait
        // can't be backdated. Dedupe by domain keeps the original landing time.
        if let data = MarkerIO.consume(Paths.mDelayAdd, enforcedUID: euid) {
            var reg = Registry.load(); var added = 0
            for d in parseDomains(data).filter(validDomain) where reg.pending[d] == nil {
                reg.pending[d] = Pending(requestedAt: now, applyAt: now + delay); added += 1
            }
            if added > 0 { reg.save(); logLine("delay-add queued \(added) domain(s) — land in \(Int(delay / 3600))h") }
        }
    }

    /// Apply delayed allows whose time has come. A failed API call keeps the entry to retry next tick
    /// (fail-closed on loosening: a domain stays blocked until the allow actually sticks).
    private func applyDueAdds(now: Double) {
        var reg = Registry.load()
        let due = reg.pending.filter { now >= $0.value.applyAt }
        guard !due.isEmpty else { return }
        guard let api = NextDNSAPI.load() else { logLine("delayed adds due but credentials unavailable — retrying"); return }
        for (d, _) in due {
            let r = api.allow(d)
            if r.ok { reg.pending.removeValue(forKey: d); logLine("delay-add APPLIED \(d) allowlist+=\(r.add)") }
            else { logLine("delay-add FAILED \(d) (allowlist+=\(r.add)) — retry next tick") }
        }
        reg.save()
    }
}
