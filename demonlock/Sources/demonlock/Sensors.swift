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
///   2. Scan nearby BSSIDs eagerly (associated AP every ~2s + full sweep every scanSeconds, fed as
///      their union) — a full sweep returns both bands of a dual-band router at once, so the
///      enforcer's anchor snapshot is rich (band-steering survives) + the policy input.
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
    private var assoc: String?             // the ASSOCIATED AP's BSSID — re-read every ~2s (unthrottled, the
                                           // live band you're on right now); nil on Ethernet/unassociated
    private var assocTs: Double = 0        // when `assoc` was last read (for honest scan freshness)
    private var fullScan: Set<String> = [] // last full scanForNetworks (ALL bands of ALL nearby APs at once)
    private var fullScanTs: Double = 0     // when that full scan landed
    private var radioOn = false            // Wi-Fi power; radio off ⇒ we report no scan (unknown)
    private let assocSampleSeconds = 2.0   // associated-AP re-read cadence (the eager live signal)
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

    /// Scan EAGERLY: re-read the associated AP every ~2s (unthrottled, so the live band is always
    /// current), and run a full all-bands scanForNetworks every scanSeconds (CoreWLAN's ~4s floor).
    /// A full sweep returns BOTH radios of a dual-band router at once; feed() unions it with the live
    /// associated AP, so the set is rich (both bands) — that richness is the band-steering fix (the
    /// anchor snapshot and every live overlap check both see all bands). On a full-scan tick the ~4s
    /// blocking scan stretches that one cycle, so the associated re-read is ~6s that tick, ~2s otherwise.
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
        // ALL CoreWLAN access happens here on scanQueue — the wifi client/interface is not
        // thread-safe, so feed() must never touch it (it reads the cached fields below).
        guard let iface = wifi.interface(), iface.powerOn() else {
            lock.lock(); radioOn = false; assoc = nil; assocTs = 0; fullScan = []; fullScanTs = 0; lock.unlock()
            return                                                       // radio off ⇒ no scan, clear all of it
        }
        let a = iface.bssid()?.lowercased()                              // associated AP — unthrottled
        var scanned: Set<String>?
        if full, let nets = try? iface.scanForNetworks(withName: nil) {  // ~4s, throttled; grabs ALL bands at once
            scanned = Set(nets.compactMap { $0.bssid?.lowercased() }.filter { !$0.isEmpty })
        }
        let now = nowEpoch()
        lock.lock()
        radioOn = true
        assoc = (a?.isEmpty == false) ? a : nil
        if assoc != nil { assocTs = now }
        if let scanned { fullScan = scanned; fullScanTs = now }
        lock.unlock()
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
        // Current BSSIDs = the live associated AP ∪ the most recent full scan, the latter kept valid for
        // a couple sweep cycles so the set stays rich (both bands) between the ~6s sweeps. Radio off, or
        // nothing visible ⇒ nil (unknown). scanTs is the freshest INCLUDED component's real observation
        // time (not "now"), so the enforcer's freshness gate sees the true age of what it's judging.
        let now = nowEpoch()
        lock.lock()
        let on = radioOn
        let a = assoc; let aTs = assocTs
        let fullValid = (now - fullScanTs) < max(settings.scanSeconds * 2, 12)
        let full = fullValid ? fullScan : []
        let fTs = fullScanTs
        lock.unlock()
        var macs = full
        var freshest = fullValid ? fTs : 0
        if let a { macs.insert(a); freshest = max(freshest, aTs) }
        let bssids: [String]? = (on && !macs.isEmpty) ? Array(macs) : nil

        let payload = FeedPayload(
            ts: now,
            lat: loc?.coordinate.latitude,
            lon: loc?.coordinate.longitude,
            acc: loc.map { $0.horizontalAccuracy },   // already validated ≥ 0 at acceptance
            fixTs: loc.map { $0.timestamp.timeIntervalSince1970 },
            bssids: bssids,
            locState: state,
            scanTs: bssids == nil ? nil : freshest
        )
        sender.send(payload)
    }
}
