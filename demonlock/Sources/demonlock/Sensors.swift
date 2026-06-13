import AppKit
import CoreLocation
import CoreWLAN
import Foundation

/// Agent-side sensor PIPE. The root enforcer is the sole judge and sole state-holder (the
/// held fix + its BSSID anchor live root-side, in heldfix.json — see LOCATION-MODEL.md).
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
    private let settings: Settings

    init(settings: Settings) { self.settings = settings }

    func start() {
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
                let doFull = nowEpoch() - lastFull >= self.settings.scanSeconds
                self.sampleWifi(full: doFull)
                if doFull { lastFull = nowEpoch() }
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
            scanTs: freshest
        )
        sender.send(payload)
    }
}
