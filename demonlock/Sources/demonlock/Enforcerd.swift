import Foundation

/// The root enforcer daemon — sole judge AND sole state-holder. Implements the per-tick
/// watcher logic of LOCATION-MODEL.md: a NEW fix is adopted (with the stable BSSIDs visible
/// at that moment as its "anchor") and evaluated; with no new fix, the held fix stays valid
/// exactly as long as enough anchor APs persist in the current scan — never judged by age
/// (stationary silence is CoreLocation's "unchanged"). When the anchor stops matching, a
/// bounded GRACE-PERIOD-LOCATION awaits a fresh fix; expiry kills the held fix ⇒ fail-closed.
/// The held fix persists root-owned across reboot/sleep, so login/wake need nothing special —
/// and the user can't forge it (root file; cdhash-pinned feed; signed agent).
/// Ticks ~1s because time is an input (countdown, TIME_IS_ANY, snooze, console, dead-agent);
/// at countdown zero, armed ⇒ `launchctl bootout gui/<uid>`. Countdown cancels the instant a
/// tick allows, so transients self-heal.
final class Enforcer {
    private let server = SecureFeedServer()
    private var settings = Settings.load()

    private var sessionUID: uid_t?       // console session tracking (standby + countdown reset)
    private var everFeedFresh = false    // transport ever up this session? gates the startup grace
    private var sessionStart = Date()
    private var countdownDeadline: Date?

    // The one location truth (persisted root-owned; survives restarts — login "just works").
    // Grace lives INSIDE it (held.graceUntil), so it survives restarts too.
    private var held: HeldFix? = HeldFixStore.read()

    func run() {
        if geteuid() != 0 { log("WARNING: not running as root — bootout will fail") }
        log("enforcerd starting (uid \(getuid()))")
        server.start()
        while true {
            let interval = tick()
            Thread.sleep(forTimeInterval: max(interval, 0.1))
        }
    }

    // MARK: tick

    private func tick() -> Double {
        let now = Date()
        settings = Settings.load()
        let poll = settings.pollSeconds
        let cdpoll = settings.countdownPollSeconds
        let armed = ArmStore.isArmed()

        // Only act for the configured user's live console session.
        guard let consoleUID = consoleUser() else {
            resetSession(nil)
            publish(phase: "standby", verdict: nil, reason: "no user logged in", now: now, armed: armed)
            return poll
        }
        guard let target = settings.enforcedUID(), consoleUID == target else {
            resetSession(consoleUID)
            let who = settings.enforcedUser.isEmpty ? "(unset)" : settings.enforcedUser
            publish(phase: "standby", verdict: nil, reason: "console user isn't the enforced user \(who)", now: now, armed: armed)
            return poll
        }
        if sessionUID != consoleUID { resetSession(consoleUID) }

        if armed && settings.wifiKeepOn { Wifi.ensureOn(settings.wifiDevice) }

        // Snooze: force-allow until the snooze time, then auto-clear.
        if let snooze = SnoozeStore.until() {
            if now < snooze {
                countdownDeadline = nil
                publish(phase: "snoozed", verdict: nil, reason: "snoozed until \(timeStr(snooze))",
                        now: now, armed: armed, snoozeUntil: snooze)
                return poll
            }
            try? SnoozeStore.set(nil)
        }

        // Build inputs from the trusted feed (availability, not perms, decides unknown).
        let feed = server.latest()
        let fresh = feed.map { now.timeIntervalSince($0.at) < settings.staleSeconds } ?? false
        let nowSec = now.timeIntervalSince1970
        var fix: (lat: Double, lon: Double)?
        var bssids: Set<String>?
        var stableScan: Set<String>?     // kept for the decision-map display
        var scanAgeSec: Double?          // how old the live scan is (display)
        var adoptedThisTick = false
        var health = Health()
        if let (p, _) = feed {
            if fresh { everFeedFresh = true }
            health.agentFeedFresh = fresh
            health.locState = p.locState
            health.needsPermAsk = ["denied", "restricted", "notDetermined", "reduced"].contains(p.locState)
            if fresh {
                // Fresh stable scan = the OPTIONAL "did I leave" check. Scans expire (the loop re-runs
                // every scanSeconds). A stale/missing scan does NOT lock you — judgeLocation only locks
                // on a fresh scan that positively contradicts the anchor (see (2) there).
                var stable: Set<String>?
                if let b = p.bssids, !b.isEmpty, let st = p.scanTs {
                    let scanAge = nowSec - st
                    if scanAge >= 0 && scanAge < max(settings.scanSeconds * 2, 30) {
                        scanAgeSec = scanAge
                        bssids = Set(b.map { $0.lowercased() })        // policy input (FOUND_IN_NEARBY_BSSID)
                        stable = bssids!.filter(isStableBSSID)         // liveness anchor signal
                    }
                }
                stableScan = stable

                let j = judgeLocation(held: held, payload: p, stable: stable, settings: settings, now: nowSec)
                held = j.held
                adoptedThisTick = j.adopted
                if j.persist, let h = held { HeldFixStore.write(h) }
                fix = j.fix
                health.fixReason = j.reason
            }
        }

        // Evaluate the policy (three-valued).
        let zones = ZoneStore.load()
        let policyText = PolicyStore.text()
        var tree: EvalNode?
        var result: Tri
        var staticReason = ""
        if let policyText, let policy = try? PolicyEngine.parse(policyText) {
            let (r, t) = PolicyEngine.evaluate(policy, PolicyInputs(now: now, fix: fix, bssids: bssids, zones: zones))
            result = r; tree = t
        } else {
            result = .unknown
            staticReason = policyText == nil ? "no policy set" : "policy is invalid"
            tree = EvalNode(kind: "ERROR", label: staticReason, result: nil)
        }

        let inside = fix.map { ZoneStore.containing(lat: $0.lat, lon: $0.lon, zones: zones) } ?? []
        let policyStr = policyText ?? ""
        health.locationTrail = locationTrail(health, held: held, fix: fix, stable: stableScan,
                                             scanAge: scanAgeSec, inside: inside, adopted: adoptedThisTick, now: nowSec)

        // Single block path — out-of-policy and can't-determine both arrive here.
        func enterBlock(_ reason: String) -> Double {
            if countdownDeadline == nil { countdownDeadline = now.addingTimeInterval(settings.countdownSeconds) }
            publish(phase: "countdown", verdict: "block", reason: reason, now: now, armed: armed,
                    deadline: countdownDeadline, tree: tree, inside: inside, policy: policyStr, health: health)
            if let dl = countdownDeadline, now >= dl, armed {
                log("countdown elapsed — bootout gui/\(consoleUID). reason: \(reason)")
                logout(consoleUID)
            }
            return cdpoll
        }

        switch result {
        case .t:
            countdownDeadline = nil
            publish(phase: "monitoring", verdict: "allow", reason: "in policy", now: now, armed: armed,
                    tree: tree, inside: inside, policy: policyStr, health: health)
            return poll

        case .f:
            return enterBlock(staticReason.isEmpty ? "out of policy" : staticReason)

        case .unknown:
            // Startup transport grace ONLY: at session start the agent process needs a few seconds
            // to launch and connect — show INITIALIZING instead of a countdown, bounded by
            // initMaxSeconds and only until the feed has been fresh once. After that, every
            // indeterminate verdict (agent killed, no held fix, grace expired) counts down.
            // INITIALIZING (no countdown) while we're still warming up: either the agent process
            // isn't reporting yet (!everFeedFresh) OR no location truth exists yet (held == nil, e.g.
            // first-ever run before CoreLocation's first fix lands — which can lag 10–30s on a Wi-Fi
            // Mac). Bounded by initMaxSeconds; once a held fix exists it drives the verdict directly.
            if (!everFeedFresh || held == nil), now.timeIntervalSince(sessionStart) < settings.initMaxSeconds {
                countdownDeadline = nil
                publish(phase: "initializing", verdict: nil, reason: "starting up — \(unknownReason(health))",
                        now: now, armed: armed, tree: tree, inside: inside, policy: policyStr, health: health)
                return poll
            }
            return enterBlock(staticReason.isEmpty ? unknownReason(health) : staticReason)
        }
    }

    // MARK: helpers

    private func resetSession(_ uid: uid_t?) {
        // New console session: reset the countdown and the startup grace. Drop the previous
        // session's last feed packet so a fast logout→login can't inherit it as "fresh" and
        // forfeit the new agent's startup grace. The held fix is KEPT — location doesn't change
        // because a different user logged in.
        sessionUID = uid; countdownDeadline = nil
        sessionStart = Date(); everFeedFresh = false
        server.clear()
    }

    private func consoleUser() -> uid_t? {
        var st = stat()
        guard lstat("/dev/console", &st) == 0 else { return nil }   // lstat avoids the stat struct/func name clash
        return st.st_uid == 0 ? nil : st.st_uid
    }

    private func logout(_ uid: uid_t) {
        Proc.run("/bin/launchctl", ["bootout", "gui/\(uid)"])
    }

    private static let fixClock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm:ss a · MMM d"; return f }()

    /// The per-tick decision trace, so status/UI always show exactly WHY location is what it is —
    /// last fix + which branch this tick took (new fix / anchor match / anchor mismatch→grace /
    /// grace over / scan unavailable→trust). No surprises.
    private func locationTrail(_ h: Health, held: HeldFix?, fix: (lat: Double, lon: Double)?,
                              stable: Set<String>?, scanAge: Double?, inside: [String], adopted: Bool, now: Double) -> [String] {
        func withZones(_ lines: [String]) -> [String] {
            lines + ["zones:      " + (inside.isEmpty ? "[]" : "[" + inside.joined(separator: ", ") + "]")]
        }
        if !h.agentFeedFresh { return withZones(["agent NOT reporting → fail-closed"]) }
        switch h.locState {
        case "reduced": return withZones(["Precise Location is OFF (approximate only) → run: demonlock perm-ask"])
        case "denied", "restricted", "notDetermined": return withZones(["Location permission OFF → run: demonlock perm-ask"])
        default: break
        }
        guard let held else { return withZones(["no CoreLocation fix yet → fail-closed"]) }

        let when = Self.fixClock.string(from: Date(timeIntervalSince1970: held.fixTs))
        let ann = held.anchor.isEmpty ? "no BSSIDs annotated yet" : "annotated with \(held.anchor.count) BSSIDs"
        var t = [String(format: "last fix:   %@  ·  %.5f, %.5f  ·  ±%.0fm  ·  %@", when, held.lat, held.lon, held.acc, ann)]
        t.append(stable != nil && scanAge != nil
            ? "last scan:  \(Int(scanAge!.rounded()))s ago · \(stable!.count) BSSIDs (live)"
            : "last scan:  none recent — macOS isn't letting the background agent scan")

        if adopted {
            t.append("this tick:  NEW fix → valid · anchored to \(held.anchor.count) nearby BSSIDs.")
        } else if let stable {
            let shared = held.anchor.filter(stable.contains).count
            if held.anchor.isEmpty {
                t.append("this tick:  no new fix · last fix had no scan (empty anchor) → can't check APs → trusting last fix.")
            } else if bssidOverlapOK(anchor: held.anchor, current: stable) {
                t.append("this tick:  no new fix → BSSIDs overlap last-fix set (\(shared)/\(held.anchor.count)) → last fix still valid.")
            } else if let g = held.graceUntil, now < g {
                t.append("this tick:  no new fix → BSSIDs do NOT overlap (0/\(held.anchor.count)) → may be invalid → grace, \(Int((g-now).rounded()))s remaining.")
            } else {
                t.append("this tick:  no new fix → BSSIDs do NOT overlap → grace over → FAIL-CLOSE initiated.")
            }
        } else {
            t.append("this tick:  no new fix · no fresh scan to check BSSIDs → trusting last fix.")
        }
        t.append("verdict:    " + (fix != nil ? "TRUSTED" : "UNKNOWN → fail-closed"))
        return withZones(t)
    }

    private func unknownReason(_ h: Health) -> String {
        if !h.agentFeedFresh { return "agent not reporting (is it running?)" }
        if let r = h.fixReason { return r }   // a held-fix reason (grace / left-the-Wi-Fi / too-fuzzy) wins
        switch h.locState {
        case "denied", "restricted": return "Location permission is off"
        case "notDetermined": return "Location permission not granted yet"
        case "reduced": return "Precise Location is off — turn it on (demonlock perm-ask)"
        case "noFix": return "no location fix yet"
        default: return "missing sensor data"
        }
    }

    private static let hhmm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f }()
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()

    private func timeStr(_ d: Date) -> String { Self.hhmm.string(from: d) }

    private func log(_ s: String) { print("[\(Self.stamp.string(from: Date()))] \(s)") }

    private func publish(phase: String, verdict: String?, reason: String, now: Date,
                         armed: Bool, snoozeUntil: Date? = nil, deadline: Date? = nil,
                         tree: EvalNode? = nil, inside: [String] = [], policy: String = "",
                         health: Health = Health()) {
        StateStore.write(StateSnapshot(
            updatedEpoch: nowEpoch(),
            lastCheckEpoch: now.timeIntervalSince1970,
            armed: armed,
            snoozeUntilEpoch: snoozeUntil?.timeIntervalSince1970,
            enforcedUser: settings.enforcedUser,
            phase: phase,
            verdict: verdict,
            reason: reason,
            countdownDeadlineEpoch: deadline?.timeIntervalSince1970,
            countdownSeconds: settings.countdownSeconds,
            pollSeconds: settings.pollSeconds,
            policyString: policy,
            tree: tree,
            insideZones: inside,
            health: health))
    }
}

// MARK: - Location state machine (pure — the security-critical core, isolated for testing)

struct LocationJudgment {
    var held: HeldFix?                       // updated record (adoption / grace), to be persisted iff `persist`
    var persist: Bool                        // held changed materially → write it to disk
    var fix: (lat: Double, lon: Double)?     // point to evaluate, or nil ⇒ location unknown ⇒ fail-closed
    var reason: String?                      // why location isn't driving an allow (status/UI)
    var adopted = false                      // a NEW fix was adopted this tick (for the decision trace)
}

/// One tick of the held-fix/anchor/grace state machine (LOCATION-MODEL.md). Pure: same inputs →
/// same outputs, no I/O, no clock — so every transition is unit-tested (the resurrection fail-open
/// was an untested transition). `stable` is the current fresh stable-BSSID scan, nil if none.
func judgeLocation(held: HeldFix?, payload p: FeedPayload, stable: Set<String>?,
                   settings: Settings, now: Double) -> LocationJudgment {
    var held = held
    var persist = false
    var reason: String?
    var adopted = false

    // (1) Adopt any STRICTLY-newer valid fix. A fresh CoreLocation fix is authoritative on its own —
    //     we do NOT require a Wi-Fi scan to use it; the scan is an optional "still here" check for
    //     later. anchor = the stable APs visible now, or [] if no scan (backfilled in (2)). The strict
    //     `>` is the anti-resurrection gate: a grace-expired fix's ts stays the high-water mark and the
    //     agent re-streams that same ts forever, so it can't be re-adopted — only a new measurement.
    if p.locState == "ok", let lat = p.lat, let lon = p.lon, let ts = p.fixTs,
       ts > (held?.fixTs ?? -.infinity) {
        if !lat.isFinite || !lon.isFinite || (p.acc ?? -1) < 0 {
            reason = "new fix invalid — not adopted"
        } else if let acc = p.acc, acc > settings.maxAccuracyMeters {
            reason = String(format: "new fix too fuzzy (±%.0fm) — not adopted", acc)
        } else {
            let anchor = (stable ?? []).sorted()
            // Persist only on a MATERIAL change — the in-memory record advances every fix (so the
            // high-water/anti-resurrection check is always current), but a moving vehicle must not
            // write heldfix.json on every fix. ~25m or an anchor change is material.
            if held == nil || abs(lat - held!.lat) > 2.5e-4 || abs(lon - held!.lon) > 2.5e-4 || anchor != held!.anchor {
                persist = true
            }
            // A new fix REPLACES the record outright (fresh coords, fresh anchor snapshot, grace cleared).
            held = HeldFix(lat: lat, lon: lon, fixTs: ts, acc: p.acc!, anchor: anchor, graceUntil: nil)
            adopted = true
        }
    }

    // (2) Trust the held fix. It locks ONLY on POSITIVE evidence of leaving — a FRESH scan that
    //     doesn't overlap a known (non-empty) anchor. A stale/missing scan or an empty anchor can't
    //     prove you left, so we trust the fix (degrading to the plain held-fix model — the Wi-Fi
    //     anchor tightens "did I leave" when the scan works, but is never required). Never deleted.
    var fix: (lat: Double, lon: Double)?
    var movedAway = false
    if var h = held {
        movedAway = stable != nil && !h.anchor.isEmpty && !bssidOverlapOK(anchor: h.anchor, current: stable!)
        if movedAway {
            if h.graceUntil == nil { h.graceUntil = now + settings.graceSeconds; persist = true }   // not reset if already set
        } else {
            // Confirmed, or can't disprove (no fresh scan / empty anchor) → trust. We do NOT backfill an
            // empty anchor from the current scan: after an offline move that would anchor the held (old)
            // coordinates to the NEW place's APs and "confirm" forever there — a fail-open. An empty anchor
            // stays empty (trusted via degradation) until a genuinely new fix re-anchors.
            if h.graceUntil != nil { h.graceUntil = nil; persist = true }
        }
        held = h
        if h.trusted(now: now) {
            fix = (h.lat, h.lon)
            if movedAway, let g = h.graceUntil {
                reason = String(format: "Wi-Fi changed — re-confirming location (%.0fs before lock)", g - now)
            }
        } else {
            reason = "left the known Wi-Fi and no fresh fix arrived — locked"
        }
    }
    return LocationJudgment(held: held, persist: persist, fix: fix, reason: reason, adopted: adopted)
}
