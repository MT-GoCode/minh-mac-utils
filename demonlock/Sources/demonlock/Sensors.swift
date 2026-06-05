import CoreLocation
import CoreWLAN
import Foundation

/// Agent-side sensor feeder: holds the CoreLocation fix and a periodic CoreWLAN BSSID scan,
/// and pushes a FeedPayload to the root enforcer over the trusted socket ~once a second.
/// Runs inside the agent's run loop. The daemon judges freshness/usability; we just report.
final class SensorFeeder: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let wifi = CWWiFiClient.shared()
    private let sender = FeedSender()
    private let scanQueue = DispatchQueue(label: "demonlock.sensors.scan")
    private let lock = NSLock()

    private var lastBSSIDs: [String]?      // nil ⇒ no usable scan (redacted/unauthorized) ⇒ unknown
    private var lastScanTs: Double?
    private let settings: Settings

    /// Optional hook so the agent UI can observe the latest locState/auth for perm-ask.
    var onUpdate: ((_ locState: String) -> Void)?

    init(settings: Settings) { self.settings = settings }

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
        startScanLoop()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.feed() }
        feed()
    }

    func currentLocState() -> String { locState(manager.location) }

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
        guard let iface = wifi.interface(),
              let nets = try? iface.scanForNetworks(withName: nil) else { return }
        let macs = nets.compactMap { $0.bssid?.lowercased() }.filter { !$0.isEmpty }
        lock.lock()
        if macs.isEmpty {
            lastBSSIDs = nil                       // visible-but-redacted or none ⇒ unknown
        } else {
            lastBSSIDs = Array(Set(macs))
            lastScanTs = nowEpoch()
        }
        lock.unlock()
    }

    private func locState(_ loc: CLLocation?) -> String {
        switch manager.authorizationStatus {
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        case .authorizedAlways, .authorizedWhenInUse, .authorized:
            return loc != nil ? "ok" : "noFix"
        @unknown default: return "noFix"
        }
    }

    private func feed() {
        let loc = manager.location
        let state = locState(loc)
        let wifiOn = wifi.interface()?.powerOn() ?? false
        lock.lock(); let macs = lastBSSIDs; let scanTs = lastScanTs; lock.unlock()

        let payload = FeedPayload(
            ts: nowEpoch(),
            ready: (state == "ok"),
            lat: loc?.coordinate.latitude,
            lon: loc?.coordinate.longitude,
            acc: loc.map { max($0.horizontalAccuracy, 0) },
            bssids: macs,
            locState: state,
            wifiOn: wifiOn,
            scanTs: scanTs
        )
        sender.send(payload)
        onUpdate?(state)
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { feed() }
}
