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
///   2. Scan nearby BSSIDs (~every scanSeconds) — the enforcer's liveness anchor + policy input.
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
    private var lastBSSIDs: [String]?      // nil ⇒ no usable scan (redacted/unauthorized) ⇒ unknown
    private var lastScanTs: Double?
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

    private func startScanLoop() {
        scanQueue.async { [weak self] in
            guard let self else { return }
            while true {
                self.scanOnce()
                Thread.sleep(forTimeInterval: max(self.settings.scanSeconds, 4))
            }
        }
    }

    private func scanOnce() {
        // ALL CoreWLAN access happens here on scanQueue — the wifi client/interface is not
        // thread-safe, so feed() must never touch it.
        let iface = wifi.interface()
        let on = iface?.powerOn() ?? false
        if !on { lock.lock(); lastBSSIDs = nil; lock.unlock() }
        guard on, let iface else { return }                              // radio off ⇒ no usable scan
        // Two BSSID sources, both LIVE (never the OS cache):
        //   1. the AP we're ASSOCIATED with — available in the background with no scan/throttle
        //      (the reliable anchor when joined to Wi-Fi; nil on Ethernet/unassociated);
        //   2. a full scanForNetworks — richer, but macOS throttles it unless we're foreground.
        var macs: [String] = []
        if let assoc = iface.bssid()?.lowercased(), !assoc.isEmpty { macs.append(assoc) }
        if let nets = try? iface.scanForNetworks(withName: nil) {
            macs += nets.compactMap { $0.bssid?.lowercased() }.filter { !$0.isEmpty }
        }
        lock.lock()
        if macs.isEmpty {
            lastBSSIDs = nil                       // visible-but-redacted or none ⇒ unknown
        } else {
            lastBSSIDs = Array(Set(macs))
            lastScanTs = nowEpoch()
        }
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
        lock.lock()
        let macs = lastBSSIDs; let scanTs = lastScanTs
        lock.unlock()

        let payload = FeedPayload(
            ts: nowEpoch(),
            lat: loc?.coordinate.latitude,
            lon: loc?.coordinate.longitude,
            acc: loc.map { $0.horizontalAccuracy },   // already validated ≥ 0 at acceptance
            fixTs: loc.map { $0.timestamp.timeIntervalSince1970 },
            bssids: macs,
            locState: state,
            scanTs: scanTs
        )
        sender.send(payload)
    }
}
