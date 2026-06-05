import Foundation

/// The root enforcer daemon. The ONLY policy evaluator. Polls the trusted feed, evaluates
/// the three-valued policy, runs the single 10s countdown for every block (out-of-policy OR
/// indeterminate), and at zero performs `launchctl bootout gui/<uid>` when armed. Publishes
/// state.json each tick. Continuously re-evaluates — the countdown cancels the instant a tick
/// returns allow, so transient false positives self-heal.
final class Enforcer {
    private let server = SecureFeedServer()
    private var settings = Settings.load()

    // per-login session / warm-up tracking
    private var sessionUID: uid_t?
    private var sessionStart = Date()
    private var everHadSensorValue = false

    private var countdownDeadline: Date?

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
        var fix: (lat: Double, lon: Double, accuracy: Double)?
        var bssids: Set<String>?
        var health = Health()
        if let (p, at) = feed {
            health.agentFeedFresh = fresh
            health.agentReady = p.ready
            health.lastFixAgeSec = now.timeIntervalSince(at)
            health.locState = p.locState
            health.wifiOn = p.wifiOn
            health.needsPermAsk = ["denied", "restricted", "servicesOff", "notDetermined"].contains(p.locState)
            if fresh {
                if p.locState == "ok", let lat = p.lat, let lon = p.lon {
                    fix = (lat, lon, p.acc ?? 0); everHadSensorValue = true
                }
                if let b = p.bssids, !b.isEmpty {
                    bssids = Set(b.map { $0.lowercased() }); everHadSensorValue = true
                    if let st = p.scanTs {
                        health.lastScanAgeSec = nowEpoch() - st
                        health.scanFresh = (nowEpoch() - st) < max(settings.scanSeconds * 2, 30)
                    }
                }
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

        let inside = fix.map { ZoneStore.containing(lat: $0.lat, lon: $0.lon, accuracy: $0.accuracy, zones: zones) } ?? []
        let policyStr = policyText ?? ""

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
            // Warm-up grace applies ONLY to an indeterminate verdict, and only before any
            // sensor value has arrived this session (bounded by initMaxSeconds).
            if !everHadSensorValue && now.timeIntervalSince(sessionStart) < settings.initMaxSeconds {
                countdownDeadline = nil
                publish(phase: "initializing", verdict: nil, reason: "starting up — \(unknownReason(health))",
                        now: now, armed: armed, tree: tree, inside: inside, policy: policyStr, health: health)
                return poll
            }
            return enterBlock(staticReason.isEmpty ? "can't determine — \(unknownReason(health))" : staticReason)
        }
    }

    // MARK: helpers

    private func resetSession(_ uid: uid_t?) {
        sessionUID = uid; sessionStart = Date(); everHadSensorValue = false; countdownDeadline = nil
    }

    private func consoleUser() -> uid_t? {
        var st = stat()
        guard lstat("/dev/console", &st) == 0 else { return nil }   // lstat avoids the stat struct/func name clash
        return st.st_uid == 0 ? nil : st.st_uid
    }

    private func logout(_ uid: uid_t) {
        Proc.run("/bin/launchctl", ["bootout", "gui/\(uid)"])
    }

    private func unknownReason(_ h: Health) -> String {
        if !h.agentFeedFresh { return "agent not reporting (is it running?)" }
        switch h.locState {
        case "denied", "restricted": return "Location permission is off"
        case "notDetermined": return "Location permission not granted yet"
        case "servicesOff": return "Location Services are off"
        case "noFix": return "no location fix yet"
        default: return "missing sensor data"
        }
    }

    private func timeStr(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f.string(from: d)
    }

    private func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        print("[\(f.string(from: Date()))] \(s)")
    }

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
