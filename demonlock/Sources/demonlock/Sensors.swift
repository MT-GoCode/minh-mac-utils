import AppKit
import CoreLocation
import CoreWLAN
import Foundation
import Security

/// Agent-side sensor PIPE. The root enforcer is the sole judge and sole state-holder (the
/// held fix + its BSSID anchor live root-side, in heldfix.json — see MODEL.md).
/// This side has exactly three jobs, all raw reporting:
///   1. Stream GENUINE CoreLocation fixes: accept a delivery only if it was measured after
///      our launch/wake epoch (Apple documentedly re-delivers a CACHED fix on (re)start —
///      the original "ALLOWED at UCLA" fail-open) and is a valid measurement.
///   2. Scan nearby BSSIDs eagerly (associated AP every ~2s + full sweep every scanSeconds) into a
///      rolling log, and report the union seen in the last scanWindowSeconds — rich (both bands of a
///      dual-band router, since a full sweep returns all radios at once) so band-steering survives;
///      empty (no Wi-Fi at all for the window) ⇒ the enforcer reads positive signal-loss. + policy input.
///   3. Heartbeat a FeedPayload ~1/s — packet arrival is the enforcer's "agent alive" signal.
/// No held-truth logic here, no expiry, no overlap decisions: a user can kill this process
/// (feed goes stale ⇒ fail-closed) but can't make it lie (cdhash-pinned socket, signed binary).
final class SensorFeeder: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let wifi = CWWiFiClient.shared()
    private let sender = FeedSender()
    private let scanQueue = DispatchQueue(label: "demonlock.sensors.scan")
    private let lock = NSLock()

    private var lastFix: CLLocation?       // newest ACCEPTED fix (measured after acquireEpoch) — held, no expiry
    private var acquireEpoch = nowEpoch()  // when we last (re)started acquiring: launch or wake
    private var seen: [String: Double] = [:] // rolling log: BSSID → last-seen epoch. Ages out per
                                             // scanWindowSeconds; NOT cleared on Wi-Fi off (it ages). feed()
                                             // reports the union of unexpired keys, or nil if the window is empty.
    private let assocSampleSeconds = 2.0     // associated-AP re-read cadence (the eager, unthrottled live signal)
    private var activityToken: NSObjectProtocol?  // App-Nap exemption, held for the app's life
    private let settings: Settings

    init(settings: Settings) { self.settings = settings }

    func start() {
        // Exempt from App Nap so a backgrounded (non-frontmost) foreground agent keeps scanning/feeding at
        // full rate instead of being QoS-throttled into "not reporting". We still allow idle SYSTEM sleep —
        // it's not our job to keep the Mac awake (that's the user's / Amphetamine's choice).
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "demonlock continuous Wi-Fi/location sensing")
        acquireEpoch = nowEpoch()                           // only measurements AFTER this are trusted
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone      // report every fix the OS bothers to compute
        manager.pausesLocationUpdatesAutomatically = false  // never let the OS pause the stream — movement
                                                            // refreshing the held fix is the load-bearing signal
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()                     // the continuous stream → didUpdateLocations
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        startScanLoop()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.feed() }
        feed()
    }

    /// On wake: advance the acceptance epoch past the nap (so the cached re-delivery Apple
    /// documents gets rejected) and restart the stream to re-acquire. Do NOT clear the last
    /// fix — the enforcer's BSSID-overlap rule decides wake: woke where you slept (anchor APs
    /// match) ⇒ instant trust; woke elsewhere ⇒ grace ⇒ fresh fix or fail-closed.
    @objc private func didWake() {
        // CLLocationManager is run-loop-affine: it must be messaged on the main run loop where it
        // was created. NSWorkspace may deliver this on another thread, so hop to main explicitly.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.acquireEpoch = nowEpoch(); self.lock.unlock()
            self.manager.stopUpdatingLocation()
            self.manager.startUpdatingLocation()
            self.feed()
        }
    }

    // MARK: CoreLocation delegate — consume the live stream

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        // Accept only GENUINE measurements: measured after our launch/wake (rejects the documented
        // cached re-delivery) and actually valid (negative accuracy = Apple's "coordinate invalid"
        // sentinel; non-finite coords are garbage). Everything else is ignored — never stored.
        lock.lock()
        let epoch = acquireEpoch
        let accepted = locs.filter {
            $0.timestamp.timeIntervalSince1970 >= epoch
                && $0.timestamp.timeIntervalSinceNow <= 2          // reject FUTURE-stamped fixes (clock skew):
                                                                    // they'd wedge the enforcer's high-water mark
                && $0.horizontalAccuracy >= 0
                && $0.coordinate.latitude.isFinite && $0.coordinate.longitude.isFinite
        }
        if let newest = accepted.max(by: { $0.timestamp < $1.timestamp }) {
            if lastFix == nil || newest.timestamp >= lastFix!.timestamp { lastFix = newest }
        }
        lock.unlock()
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        // Transient failure: keep the held truth (it's still the last genuine measurement);
        // just log. Auth loss is handled by didChangeAuthorization; sleep by didWake.
        NSLog("demonlock sensors: location error: \(error.localizedDescription)")
    }

    // Defensive: if the OS ever pauses the stream (auto-pause never resumes on its own with the
    // legacy API), restart it immediately — a paused stream would mean movement stops refreshing
    // the held fix, which is the one signal the whole model leans on.
    func locationManagerDidPauseLocationUpdates(_ m: CLLocationManager) {
        NSLog("demonlock sensors: stream paused by OS — restarting")
        m.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedAlways, .authorized: m.startUpdatingLocation()
        default: break
        }
        feed()
    }

    // MARK: Wi-Fi scan

    /// Scan EAGERLY into the rolling log: re-read the associated AP every ~2s (unthrottled, so the live
    /// band is always current — the key safety net: while joined you ALWAYS log ≥1 BSSID, so an empty
    /// window means genuine signal-loss, not a throttle blip), and run a full all-bands scanForNetworks
    /// every scanSeconds (CoreWLAN's ~4s floor) which returns BOTH radios of a dual-band router at once.
    /// On a full-scan tick the ~4s blocking scan stretches that cycle, so the associated re-read is ~6s
    /// that tick, ~2s otherwise.
    private func startScanLoop() {
        scanQueue.async { [weak self] in
            guard let self else { return }
            var lastFull = 0.0
            while true {
                // CRITICAL: drain CoreWLAN's autoreleased objects EVERY cycle. Without this pool, a bare
                // while-loop on a non-runloop thread never drains them — scanForNetworks/bssid() leak
                // forever → the agent grows to GBs over days (esp. with no sleep), gets jetsam-killed /
                // throttled, stops feeding, and the daemon fail-closes. This pool is the fix.
                autoreleasepool {
                    let doFull = nowEpoch() - lastFull >= self.settings.scanSeconds
                    self.sampleWifi(full: doFull)
                    if doFull { lastFull = nowEpoch() }
                }
                Thread.sleep(forTimeInterval: self.assocSampleSeconds)
            }
        }
    }

    private func sampleWifi(full: Bool) {
        // ALL CoreWLAN access happens here on scanQueue (the wifi client/interface is not thread-safe).
        // We only ADD what we see to the rolling log; we never clear it. On radio-off we add nothing and
        // let it age — so a momentary blip is bridged, but a sustained Wi-Fi loss empties the window,
        // which the enforcer reads as positive signal-loss (→ grace), not "can't tell" (→ trust).
        guard let iface = wifi.interface(), iface.powerOn() else { return }   // radio off ⇒ nothing new
        var macs: [String] = []
        if let a = iface.bssid()?.lowercased(), !a.isEmpty { macs.append(a) } // associated AP — unthrottled
        if full, let nets = try? iface.scanForNetworks(withName: nil) {       // ~4s, throttled; ALL bands at once
            macs += nets.compactMap { $0.bssid?.lowercased() }.filter { !$0.isEmpty }
        }
        guard !macs.isEmpty else { return }
        let now = nowEpoch()
        lock.lock(); for m in macs { seen[m] = now }; lock.unlock()
    }

    // MARK: feed

    /// Latest ACCEPTED measurement. We never read the OS's cached `manager.location` property —
    /// that's how a previous session's coordinate used to leak in. The root enforcer decides
    /// everything else (adoption, anchor overlap, grace).
    private func currentFix() -> CLLocation? {
        lock.lock(); let f = lastFix; lock.unlock()
        return f
    }

    private func locState(_ loc: CLLocation?) -> String {
        switch manager.authorizationStatus {
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        case .authorizedAlways, .authorizedWhenInUse, .authorized:
            // "Approximate Location" (reduced accuracy) yields 1–20km fixes — useless for a
            // geofence and a fail-open trap. Treat it as a permission gap, not a usable fix.
            if manager.accuracyAuthorization != .fullAccuracy { return "reduced" }
            return loc != nil ? "ok" : "noFix"
        @unknown default: return "noFix"
        }
    }

    private func feed() {
        let loc = currentFix()
        let state = locState(loc)
        // Report the UNION of every BSSID seen in the last scanWindowSeconds (prune the rest). Empty ⇒
        // nil: no Wi-Fi signal at all for the whole window (off / unjoined / left RF range), which the
        // enforcer reads as positive signal-loss. scanTs is the freshest entry's real time (nil iff empty),
        // so the enforcer's freshness gate sees the true age of what it's judging.
        let now = nowEpoch()
        let cutoff = now - settings.scanWindowSeconds
        lock.lock()
        seen = seen.filter { $0.value >= cutoff }
        let macs = Array(seen.keys)
        let freshest = seen.values.max()
        lock.unlock()
        let bssids: [String]? = macs.isEmpty ? nil : macs

        let payload = FeedPayload(
            ts: now,
            lat: loc?.coordinate.latitude,
            lon: loc?.coordinate.longitude,
            acc: loc.map { $0.horizontalAccuracy },   // already validated ≥ 0 at acceptance
            fixTs: loc.map { $0.timestamp.timeIntervalSince1970 },
            bssids: bssids,
            locState: state,
            scanTs: freshest,
            guiPids: currentGuiPids()
        )
        sender.send(payload)
    }

    /// PIDs of the user's GUI apps for the enforcer's LOCKED kill list. We SIGKILL every foreground
    /// (`.regular`) app — including Apple ones like Safari — PLUS third-party menubar (`.accessory`)
    /// apps, so a distraction repackaged as LSUIElement can't dodge the lockout. NEVER killed: an app
    /// in the effective safe-apps list whose LIVE code signature is VERIFIED (Apple-rooted + that bundle id +
    /// that Team ID — so a distraction that merely spoofs a whitelisted bundle id from another signer
    /// is still killed; Team ID survives app auto-updates); Apple's own `.accessory` items (`com.apple.*`);
    /// nil-bundle helpers; and this agent itself (spared by PID, so the sensor survives the lockout).
    /// the safe-apps list is reloaded each feed (a register/remove takes effect live). feed() runs on main.
    private func currentGuiPids() -> [Int32] {
        SensorFeeder.guiKillTargets(excludingPID: getpid()).map(\.pid)
    }

    /// The lockout kill TARGETS for the current session — every `.regular` app PLUS non-Apple
    /// `.accessory` (menubar) apps, MINUS verified spares, Apple `.accessory` items, and `excludingPID`.
    /// Shared by the agent's feed (`currentGuiPids`) AND `demonlock test-lockout`, so a test closes
    /// exactly what a real lockout would. Menubar sparing VERIFIES the signature ("anchor apple" — a
    /// Developer-ID cert can't satisfy it), not the bundle-id string, so a distraction stamped
    /// "com.apple.…" can't dodge it.
    static func guiKillTargets(excludingPID me: pid_t) -> [(pid: Int32, name: String)] {
        let spare = SafeApps.effectiveMap()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier > 0, app.processIdentifier != me else { return nil }
            let bid = app.bundleIdentifier ?? ""
            if let e = spare[bid], spareVerified(app, bid: bid, team: e.tid, rootOwned: e.rootOwned) { return nil }
            let kill: Bool
            switch app.activationPolicy {
            case .regular:   kill = true
            case .accessory: kill = !codeSatisfies(app, "anchor apple")
            default:         kill = false     // .prohibited — no user-facing window
            }
            return kill ? (app.processIdentifier, app.localizedName ?? bid) : nil
        }
    }

    /// True iff `app` is genuinely a whitelisted app. Two regimes, picked by who could have put the
    /// bundle on disk — fails closed (kill) on any doubt:
    ///   • ROOT-OWNED bundle (our own apps: demonlock/wtalk/remote-agent-connector/msv2/stayup
    ///     install to /Applications root:wheel) → only sudo could have placed/modified it, and the
    ///     adversary has no sudo. So we
    ///     just require an INTACT signature with the matching identifier, ANY identity. This is what
    ///     keeps your own apps spared even if you LOSE your Developer ID and fall back to self-signed
    ///     or ad-hoc (those aren't Apple-rooted and carry no Team ID) — `team` is unused for these.
    ///   • Not root-owned (a third-party app in /Applications, possibly user-owned) → require the
    ///     VENDOR's Apple-rooted Team ID (`anchor apple generic` + leaf OU). That's THEIR team, so it's
    ///     independent of your signing identity, and Team (not cdhash) survives their auto-updates.
    static func spareVerified(_ app: NSRunningApplication, bid: String, team: String, rootOwned: Bool) -> Bool {
        if rootOwned {
            // Regime A: the entry declares it must be root-owned. Require a genuinely root-owned bundle
            // (unmodifiable without sudo) with an intact signature carrying this identifier — ANY signer,
            // so it survives losing the Developer ID.
            return Self.rootOwnedBundle(app.bundleURL) && Self.codeSatisfies(app, "identifier \"\(bid)\"")
        }
        // Regime B: Developer-ID (anchor apple generic + bid + team OU). REFUSED for our own team — we
        // hold that key, so it'd be satisfiable by any bundle we sign. Own apps must be root-owned. [M8]
        if team == Self.ownTeamID { return false }
        return Self.codeSatisfies(app,
            "anchor apple generic and identifier \"\(bid)\" and certificate leaf[subject.OU] = \"\(team)\"")
    }

    /// Our Developer ID Team — own-team entries must go through Regime A (root ownership), never the
    /// Developer-ID Regime B, because we hold this key. safe-apps register enforces the same on input.
    static let ownTeamID = "BULCQM9J2V"

    /// Does the running process's live code signature satisfy `requirement`? Fails closed (false) on
    /// any error — no SecCode, bad requirement string, invalid signature. The audit-token-via-PID guest
    /// lookup pins it to the actual running code (a replaced/modified binary fails validity).
    private static func codeSatisfies(_ app: NSRunningApplication, _ requirement: String) -> Bool {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid as String: app.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    /// The bundle is owned by root and not group/other-writable — i.e. unmodifiable without sudo.
    private static func rootOwnedBundle(_ url: URL?) -> Bool {
        guard let bundleURL = url?.standardizedFileURL else { return false }
        func rootOwnedNotGroupOtherWritable(_ p: String) -> Bool {
            var st = stat()
            guard stat(p, &st) == 0 else { return false }
            return st.st_uid == 0 && (st.st_mode & (S_IWGRP | S_IWOTH)) == 0
        }
        // Check the bundle root AND its main executable. Regime A accepts ANY signer, so filesystem
        // ownership is the ONLY barrier — and the executable is what actually runs, so a user-writable
        // inner path under a root-owned .app must not be able to pass by swapping the Mach-O and
        // ad-hoc-re-signing it. [review M6]
        guard rootOwnedNotGroupOtherWritable(bundleURL.path) else { return false }
        let exe = Bundle(url: bundleURL)?.executableURL?.resolvingSymlinksInPath().path
            ?? bundleURL.appendingPathComponent("Contents/MacOS").path
        return rootOwnedNotGroupOtherWritable(exe)
    }
}
