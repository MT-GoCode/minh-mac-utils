import Foundation

/// The root enforcer daemon — sole judge AND sole state-holder. ONE question per tick: is the user
/// PROVABLY in policy right now? Confident YES → allow; anything else (out of policy, or can't tell)
/// → 10 s countdown → LOCKED. Fail-closed by default; there are no open-ended reprieves.
///
/// Location truth is the held fix (persisted root-owned) with ONE confidence timer (`confirmedUntil`):
/// a new fix or the anchor still overlapping the live scan CONFIRMS it (pushes the timer); anything
/// that doesn't confirm — Wi-Fi off, anchor mismatch, agent dead, agent starting, just-woke — lets it
/// run out → STALE → location unknown → fail-closed. One timer, every "no signal" case coasts the same.
///
/// LOCKED enforcement = root force-kills the user's GUI apps EXCEPT the agent (so the sensor survives and
/// recovery is detected instantly); if the agent itself is dead, `killall WindowServer` (nuclear, rate-
/// limited so the agent can relaunch). sshd/tmux survive → you can SSH in and `sudo demonlock disarm`.
final class Enforcer {
    private let server = SecureFeedServer()
    private var settings = Settings.load()

    private var sessionUID: uid_t?          // console session tracking (standby + countdown reset)
    private var countdownDeadline: Date?    // set on entering a block; nil while allowed
    private var nextNuclear: Date?          // rate-limit for the nuclear (agent-dead) WindowServer kill
    private var nextAgentKick: Date?        // rate-limit for force-restarting a wedged-but-alive agent
    private var lastAgentSeen = Date()      // last fresh feed — gates the startup/recovery grace below

    // The one location truth (persisted root-owned; survives restarts — login "just works").
    private var held: HeldFix? = HeldFixStore.read()
    private var lastHeldPersist = Date.distantPast   // throttle for heartbeat-persisting confirmedUntil
    private lazy var bonjourName: String? = localBonjourName()   // stable .local SSH target (cached)

    private static let feedFreshSeconds = 5.0        // no packet within this ⇒ agent considered dead
    private static let nuclearRelockSeconds = 15.0   // WS-kill cadence when the agent is dead: long enough for
                                                     // KeepAlive to relaunch the agent + report (~10s), short
                                                     // enough that kill-looping the agent doesn't buy free GUI
    private static let heldPersistSeconds = 30.0     // re-persist a confirmed fix at least this often, so an
                                                     // enforcer restart reads a still-LIVE confirmedUntil (not a
                                                     // stale one written only on the last material location change)
    private static let agentKickSeconds = 30.0       // force-restart a wedged-but-alive agent at most this often
    private static let agentGraceSeconds = 25.0      // startup/recovery grace: an agent silent for LESS than this
                                                     // is "starting up / brief blip" — neither kickstart nor the
                                                     // nuclear WS-kill fire (so a normal login/boot/wake gap
                                                     // never nukes your GUI; only a genuinely-gone agent does)

    func run() {
        if geteuid() != 0 { log("WARNING: not running as root — the GUI lockout (kill) will fail") }
        log("enforcerd starting (uid \(getuid()))")
        server.start()
        while true {
            let interval = autoreleasepool { tick() }   // drain any autoreleased objects each tick (defensive)
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

        // STANDBY: only enforce the configured user's live console session.
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

        // SNOOZED: force-allow until the snooze time, then auto-clear.
        if let snooze = SnoozeStore.until() {
            if now < snooze {
                clearCountdown()
                // Keep the agent-liveness grace clock fresh while snoozed (we aren't enforcing, so the
                // agent's silence mustn't accumulate). Otherwise a long snooze leaves lastAgentSeen stale,
                // and a dead agent at snooze expiry would skip its 25s startup/recovery grace → an immediate
                // nuclear WS-kill instead of the normal "let the just-kickstarted agent relaunch" window.
                lastAgentSeen = now; nextAgentKick = nil
                publish(phase: "snoozed", verdict: nil, reason: "snoozed until \(timeStr(snooze))",
                        now: now, armed: armed, snoozeUntil: snooze)
                return poll
            }
            try? SnoozeStore.set(nil)
        }

        // Process the agent feed ONLY if it's reporting right now (recent packet). A stale packet (agent
        // dead) is NOT processed — so it can't confirm the held fix; confirmedUntil just coasts → lock.
        let nowSec = now.timeIntervalSince1970
        let feed = server.latest()
        let agentLive = feed.map { now.timeIntervalSince($0.at) < Self.feedFreshSeconds } ?? false
        var bssids: Set<String>?
        var stableScan: Set<String>?
        var scanAgeSec: Double?
        var adoptedThisTick = false
        var confirmedThisTick = false
        var guiKillList: [Int32] = []
        var locState = "unknown"
        var locReason: String?
        var needsPermAsk = false
        if let (p, _) = feed, agentLive {
            guiKillList = p.guiPids
            locState = p.locState
            needsPermAsk = ["denied", "restricted", "notDetermined", "reduced"].contains(p.locState)
            var stable: Set<String>?
            if let b = p.bssids, !b.isEmpty, let st = p.scanTs {
                let scanAge = nowSec - st
                // Backstop only — the agent already prunes to scanWindowSeconds; allow delivery slack.
                if scanAge >= 0 && scanAge < settings.scanWindowSeconds + 10 {
                    scanAgeSec = scanAge
                    bssids = Set(b.map { $0.lowercased() })        // policy input (FOUND_IN_NEARBY_BSSID)
                    stable = bssids!.filter(isStableBSSID)         // liveness anchor signal
                }
            }
            stableScan = stable
            let j = judgeLocation(held: held, payload: p, stable: stable, settings: settings, now: nowSec)
            held = j.held
            adoptedThisTick = j.adopted
            confirmedThisTick = j.confirmed
            locReason = j.reason
            // Persist on a material change (coords/anchor) AND as a heartbeat at least every
            // heldPersistSeconds while merely confirming — otherwise the in-memory confirmedUntil bumps
            // never reach disk, and an enforcer restart would read a stale (expired) timer and falsely
            // lock you while you sat still. The heartbeat keeps the on-disk timer within ~30s of live.
            if let h = held, j.persist || (j.confirmed && now.timeIntervalSince(lastHeldPersist) >= Self.heldPersistSeconds) {
                HeldFixStore.write(h); lastHeldPersist = now
            }
        }
        // else: agent not reporting → no confirmation → held.confirmedUntil coasts → eventually STALE.

        // Watchdog: a wedged-but-alive agent (throttled / stuck) stops feeding, and KeepAlive only restarts a
        // DEAD process — so once it's been silent PAST the startup/recovery grace, force-restart it (launchctl
        // kickstart -k), rate-limited. The grace is what keeps us from killing a normally-launching agent.
        if agentLive {
            lastAgentSeen = now
            nextAgentKick = nil
        } else if armed, now.timeIntervalSince(lastAgentSeen) >= Self.agentGraceSeconds,
                  now >= (nextAgentKick ?? .distantPast) {
            log("agent silent \(Int(now.timeIntervalSince(lastAgentSeen)))s → kickstart -k gui/\(consoleUID)/\(Paths.agentLabel)")
            Proc.run("/bin/launchctl", ["kickstart", "-k", "gui/\(consoleUID)/\(Paths.agentLabel)"])
            nextAgentKick = now.addingTimeInterval(Self.agentKickSeconds)
        }

        // The location truth: a LIVE held fix, or nil (unknown → fail-closed).
        let fix: (lat: Double, lon: Double)? = {
            guard let h = held, h.live(now: nowSec) else { return nil }
            return (h.lat, h.lon)
        }()

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
        let ssh = sshHint(consoleUID: consoleUID)
        var health = Health()
        health.agentFeedFresh = agentLive
        health.locState = locState
        health.needsPermAsk = needsPermAsk
        health.fixReason = locReason
        health.locationTrail = locationTrail(agentLive: agentLive, locState: locState, held: held, fix: fix,
                                             stable: stableScan, scanAge: scanAgeSec, adopted: adoptedThisTick,
                                             confirmed: confirmedThisTick, inside: inside, now: nowSec)

        // Single block path — out-of-policy and can't-determine both arrive here.
        func enterBlock(_ reason: String) -> Double {
            if countdownDeadline == nil { countdownDeadline = now.addingTimeInterval(settings.countdownSeconds) }
            let elapsed = countdownDeadline.map { now >= $0 } ?? false
            if elapsed, armed {
                lockOut(agentLive: agentLive, guiPids: guiKillList, now: now)
            } else {
                nextNuclear = nil          // still warning; not locked yet
            }
            publish(phase: elapsed ? "locked" : "countdown", verdict: "block", reason: reason, now: now,
                    armed: armed, deadline: countdownDeadline, tree: tree, inside: inside, policy: policyStr,
                    ssh: ssh, health: health)
            return cdpoll
        }

        switch result {
        case .t:
            clearCountdown()
            publish(phase: "monitoring", verdict: "allow", reason: "in policy", now: now, armed: armed,
                    tree: tree, inside: inside, policy: policyStr, ssh: ssh, health: health)
            return poll
        case .f:
            return enterBlock(staticReason.isEmpty ? "out of policy" : staticReason)
        case .unknown:
            return enterBlock(staticReason.isEmpty ? unknownReason(health) : staticReason)
        }
    }

    // MARK: enforcement

    /// LOCKED action. Agent alive → SIGKILL the user's GUI apps it reported (it excluded itself, so the
    /// sensor survives → instant recovery). Agent dead → nuclear `killall -9 WindowServer` (SIGKILL —
    /// uncatchable, so the GUI actually tears down to the login window; sshd/tmux survive), rate-limited so
    /// the agent gets a window to relaunch and report. (Plain `killall` = SIGTERM, which WindowServer
    /// survives — that was the "logged every 15s, nothing happened" bug.)
    private func lockOut(agentLive: Bool, guiPids: [Int32], now: Date) {
        if agentLive {
            for pid in guiPids where pid > 1 { kill(pid, SIGKILL) }
            nextNuclear = nil
        } else if now.timeIntervalSince(lastAgentSeen) >= Self.agentGraceSeconds,
                  nextNuclear == nil || now >= nextNuclear! {
            // Only nuke once the agent has been gone PAST the startup grace — a normal login/boot/wake gap
            // (held fix coasts, agent re-confirms in ~5s) must never trigger the GUI-wide kill.
            log("LOCKED + agent gone \(Int(now.timeIntervalSince(lastAgentSeen)))s → killall -9 WindowServer")
            Proc.run("/usr/bin/killall", ["-9", "WindowServer"])
            nextNuclear = now.addingTimeInterval(Self.nuclearRelockSeconds)
        }
    }

    // MARK: helpers

    private func clearCountdown() { countdownDeadline = nil; nextNuclear = nil }

    private func resetSession(_ uid: uid_t?) {
        // New console session: reset the countdown. Drop the previous session's last feed packet so a
        // fast logout→login can't inherit it as "fresh". The held fix is KEPT — it persists across logins
        // and is judged on its own confidence timer (no per-login reprieve, so no oscillation).
        sessionUID = uid
        clearCountdown()
        nextAgentKick = nil
        lastAgentSeen = Date()    // give the new session's agent the full startup grace before we intervene
        server.clear()
    }

    private func consoleUser() -> uid_t? {
        var st = stat()
        guard lstat("/dev/console", &st) == 0 else { return nil }   // lstat avoids the stat struct/func name clash
        return st.st_uid == 0 ? nil : st.st_uid
    }

    private func userName(_ uid: uid_t) -> String? {
        guard let pw = getpwuid(uid) else { return nil }
        return String(cString: pw.pointee.pw_name)
    }

    /// "ssh minh@192.168.1.42 · minh@minhs-mac.local" — shown so you can SSH in (sshd/tmux survive a
    /// lockout) and `sudo demonlock disarm`. IP recomputed each tick (cheap); .local name cached.
    private func sshHint(consoleUID: uid_t) -> String? {
        let user = userName(consoleUID) ?? settings.enforcedUser
        var targets: [String] = []
        if let ip = localIPv4s().first { targets.append(ip) }
        if let b = bonjourName { targets.append(b) }
        guard !targets.isEmpty, !user.isEmpty else { return nil }
        return "ssh " + targets.map { "\(user)@\($0)" }.joined(separator: "  ·  ")
    }

    private static let fixClock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm:ss a · MMM d"; return f }()

    /// The per-tick decision trace, so status/UI always show exactly WHY location is what it is — last fix
    /// + which branch this tick took (new fix / anchor overlap → confirmed / coasting / expired → lock).
    private func locationTrail(agentLive: Bool, locState: String, held: HeldFix?, fix: (lat: Double, lon: Double)?,
                               stable: Set<String>?, scanAge: Double?, adopted: Bool, confirmed: Bool,
                               inside: [String], now: Double) -> [String] {
        func withZones(_ lines: [String]) -> [String] {
            lines + ["zones:      " + (inside.isEmpty ? "[]" : "[" + inside.joined(separator: ", ") + "]")]
        }
        guard let held else {
            return withZones([agentLive ? "waiting for the first location fix → fail-closed"
                                        : "agent NOT reporting & no fix yet → fail-closed"])
        }
        if agentLive {
            switch locState {
            case "reduced": return withZones(["Precise Location is OFF (approximate only) → run: demonlock perm-ask"])
            case "denied", "restricted", "notDetermined": return withZones(["Location permission OFF → run: demonlock perm-ask"])
            default: break
            }
        }

        let when = Self.fixClock.string(from: Date(timeIntervalSince1970: held.fixTs))
        let ann = held.anchor.isEmpty ? "no BSSIDs annotated yet" : "annotated with \(held.anchor.count) BSSIDs"
        var t = [String(format: "last fix:   %@  ·  %.5f, %.5f  ·  ±%.0fm  ·  %@", when, held.lat, held.lon, held.acc, ann)]
        if !agentLive {
            t.append("last scan:  agent NOT reporting")
        } else if let stable, let scanAge {
            t.append("last scan:  \(Int(scanAge.rounded()))s ago · \(stable.count) BSSIDs (live)")
        } else {
            t.append("last scan:  none recent")
        }

        let left = max(0, Int((held.confirmedUntil - now).rounded()))
        if adopted {
            t.append("this tick:  NEW fix → confirmed · valid \(Int(settings.graceSeconds))s")
        } else if confirmed, let stable {
            let shared = held.anchor.filter(stable.contains).count
            t.append("this tick:  anchor overlaps live scan (\(shared)/\(held.anchor.count)) → confirmed · \(left)s left")
        } else {
            let why = !agentLive ? "agent not reporting"
                    : (held.anchor.isEmpty ? "last fix had no scan (empty anchor)"
                    : (stable == nil ? "no Wi-Fi signal at all (off / left range)"
                    : "BSSIDs do NOT overlap (0/\(held.anchor.count))"))
            t.append(held.live(now: now)
                ? "this tick:  \(why) → coasting, \(left)s of confidence left"
                : "this tick:  \(why) → confidence expired → FAIL-CLOSE")
        }
        t.append("verdict:    " + (fix != nil ? "TRUSTED" : "UNKNOWN → fail-closed"))
        return withZones(t)
    }

    private func unknownReason(_ h: Health) -> String {
        if !h.agentFeedFresh { return "agent not reporting (is it running?)" }
        if let r = h.fixReason { return r }
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
                         ssh: String? = nil, health: Health = Health()) {
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
            sshAddr: ssh,
            health: health))
    }
}

// MARK: - Location state machine (pure — the security-critical core, isolated for testing)

struct LocationJudgment {
    var held: HeldFix?      // updated record (adoption / confirmation), to be persisted iff `persist`
    var persist: Bool       // held changed materially (coords/anchor) → write it to disk
    var adopted: Bool       // a NEW fix was adopted this tick
    var confirmed: Bool     // the held fix was positively confirmed this tick (new fix OR anchor overlap)
    var reason: String?     // why location isn't confirmed (status/UI)
}

/// One tick of the held-fix / anchor / confidence state machine (MODEL.md). Pure: same inputs → same
/// outputs, no I/O, no clock — every transition is unit-tested. Called ONLY when the agent is reporting;
/// `stable` is the current rolling-window stable-BSSID scan, nil if none this window. The caller decides
/// LIVE/STALE from `held.confirmedUntil`; this function only adopts new fixes and pushes that timer on
/// positive confirmation (a new fix, or the anchor still overlapping the live scan).
func judgeLocation(held: HeldFix?, payload p: FeedPayload, stable: Set<String>?,
                   settings: Settings, now: Double) -> LocationJudgment {
    var held = held
    var persist = false
    var adopted = false
    var confirmed = false
    var reason: String?

    // (1) Adopt any STRICTLY-newer valid fix — itself a confirmation. The strict `>` is the
    //     anti-resurrection gate: a stale fix re-streamed with the same ts can't masquerade as new.
    if p.locState == "ok", let lat = p.lat, let lon = p.lon, let ts = p.fixTs,
       ts > (held?.fixTs ?? -.infinity) {
        if !lat.isFinite || !lon.isFinite || (p.acc ?? -1) < 0 {
            reason = "new fix invalid — not adopted"
        } else if let acc = p.acc, acc > settings.maxAccuracyMeters {
            reason = String(format: "new fix too fuzzy (±%.0fm) — not adopted", acc)
        } else {
            let anchor = (stable ?? []).sorted()       // FROZEN snapshot; never grown afterward
            // Persist only on a MATERIAL change (~25m or anchor change) — a moving vehicle must not write
            // heldfix.json every fix, and confirmedUntil bumps alone (every tick at home) must not either.
            if held == nil || abs(lat - held!.lat) > 2.5e-4 || abs(lon - held!.lon) > 2.5e-4 || anchor != held!.anchor {
                persist = true
            }
            held = HeldFix(lat: lat, lon: lon, fixTs: ts, acc: p.acc!, anchor: anchor, confirmedUntil: now + settings.graceSeconds)
            adopted = true; confirmed = true
        }
    }

    // (2) Confirm-or-coast. Besides a new fix, the held fix is CONFIRMED when the live scan still overlaps
    //     its (non-empty) anchor → push confirmedUntil. A missing or non-overlapping scan does NOT confirm,
    //     so the timer just runs out → STALE → fail-closed. We never grow/backfill the anchor (an offline
    //     move would otherwise pin old coords to a new place's APs — a fail-open).
    if var h = held, !adopted {
        if let stable, !h.anchor.isEmpty, bssidOverlapOK(anchor: h.anchor, current: stable) {
            h.confirmedUntil = now + settings.graceSeconds      // in-memory push (not a material write)
            held = h
            confirmed = true
        } else if reason == nil {
            let why = !h.anchor.isEmpty && stable != nil ? "left the known Wi-Fi"
                    : (stable == nil ? "no Wi-Fi signal" : "no anchor to check")
            reason = h.live(now: now)
                ? String(format: "%@ — re-checking location (%.0fs before lock)", why, h.confirmedUntil - now)
                : "\(why) — location unconfirmed, locked"
        }
    }
    return LocationJudgment(held: held, persist: persist, adopted: adopted, confirmed: confirmed, reason: reason)
}
