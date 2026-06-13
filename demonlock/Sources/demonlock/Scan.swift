import AppKit
import CoreLocation
import CoreWLAN
import Foundation

/// Continuously scans nearby Wi-Fi, accumulating a set of (SSID, BSSID) seen across
/// the whole walk, until Ctrl+C. BSSID (the AP hardware MAC) is the strong identifier;
/// macOS only reveals it to a Location-authorized process, so we request Location first.
///
/// Output goes to stdout AND to ~/demonlock-scan-live.txt (overwritten each scan) so it
/// can be observed even when launched via `open` (no terminal stdout).
private final class ScanController: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let client = CWWiFiClient.shared()
    private let scanQueue = DispatchQueue(label: "demonlock.scan")
    private let lock = NSLock()

    struct AP { var ssid: String; var bssid: String; var rssi: Int; var channel: Int; var count: Int }

    private var seen: [String: AP] = [:]     // keyed by BSSID
    private var authorized = false
    private var scanning = false
    private var sawRedaction = false
    private var scanNo = 0

    private let livePath = (NSHomeDirectory() as NSString).appendingPathComponent("demonlock-scan-live.txt")

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        emit("demonlock scan — requesting Location permission (needed to un-redact BSSIDs)…\n")
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
        handleAuth(manager.authorizationStatus)
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { handleAuth(m.authorizationStatus) }

    private func handleAuth(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse, .authorized:
            guard !authorized else { return }
            authorized = true
            emit("AUTH: Location authorized ✓ — scanning every ~4s. Walk the floor; Ctrl+C when done.\n\n")
            beginScanning()
        case .notDetermined:
            emit("AUTH: notDetermined — waiting for you to click Allow on the Location prompt…\n")
        case .denied, .restricted:
            emit("""
            AUTH: DENIED — macOS will redact every BSSID, so this can't work.
            Fix: System Settings ▸ Privacy & Security ▸ Location Services ▸ enable Demonlock, then rerun.
            (Or reset with: tccutil reset Location com.demonlock)

            """)
        @unknown default: break
        }
    }

    private func beginScanning() {
        guard !scanning else { return }
        scanning = true
        scanQueue.async { [weak self] in
            while true {
                self?.scanOnce()
                Thread.sleep(forTimeInterval: 4.0)   // CoreWLAN scans are rate-limited; ~4s is safe
            }
        }
    }

    private func scanOnce() {
        guard let iface = client.interface() else { emit("(no Wi-Fi interface found)\n"); return }
        let nets: Set<CWNetwork>
        do { nets = try iface.scanForNetworks(withName: nil) }
        catch { emit("scan error: \(error.localizedDescription) (rate-limited? will retry)\n"); return }

        lock.lock()
        scanNo += 1
        let n = scanNo
        var newCount = 0, redacted = 0
        for net in nets {
            guard let bssid = net.bssid, !bssid.isEmpty else { redacted += 1; continue }   // nil ⇒ redacted
            let ssid = net.ssid ?? "(hidden)"
            if var ap = seen[bssid] {
                ap.rssi = net.rssiValue; ap.count += 1; seen[bssid] = ap
            } else {
                seen[bssid] = AP(ssid: ssid, bssid: bssid, rssi: net.rssiValue,
                                 channel: net.wlanChannel?.channelNumber ?? 0, count: 1)
                newCount += 1
            }
        }
        if redacted > 0 { sawRedaction = true }
        let snapshot = seen
        lock.unlock()
        render(snapshot, scan: n, new: newCount, visible: nets.count, redacted: redacted)
    }

    private func render(_ aps: [String: AP], scan: Int, new: Int, visible: Int, redacted: Int) {
        let bySSID = Dictionary(grouping: aps.values, by: { $0.ssid })
        var s = "── scan #\(scan): \(aps.count) unique BSSIDs across \(bySSID.count) networks "
        s += "(+\(new) new, \(visible) visible now"
        s += redacted > 0 ? ", \(redacted) REDACTED) ──\n" : ") ──\n"
        if aps.isEmpty && redacted > 0 {
            s += "  ⚠️  Networks ARE visible but every BSSID is redacted despite authorization.\n"
            s += "      macOS \(ProcessInfo.processInfo.operatingSystemVersionString) is withholding BSSIDs — tell Claude.\n"
        }
        for ssid in bySSID.keys.sorted() {
            s += "  \(ssid)\n"
            for ap in bySSID[ssid]!.sorted(by: { $0.bssid < $1.bssid }) {
                let tag = isStableBSSID(ap.bssid) ? "stable" : "random"
                s += "      \(ap.bssid)  [\(tag)]  ch\(ap.channel)  \(ap.rssi)dBm  ×\(ap.count)\n"
            }
        }
        emit(s + "\n")
    }

    func printFinalAndExit() {
        lock.lock(); let aps = seen; let redacted = sawRedaction; lock.unlock()
        let bssids = aps.values.map { $0.bssid }.sorted()
        let stable = bssids.filter { isStableBSSID($0) }
        var s = "\n══════ FINAL: \(bssids.count) unique BSSIDs (\(stable.count) stable hardware APs)"
        s += redacted ? "  — some scans were redacted ══════\n" : " ══════\n"
        func quoted(_ xs: [String]) -> String { xs.map { "\"\($0)\"" }.joined(separator: ", ") }
        s += "\nRECOMMENDED (stable hardware BSSIDs — these don't rotate):\n"
        s += "  FOUND_IN_NEARBY_BSSID([\(quoted(stable.isEmpty ? bssids : stable))])\n"
        s += "\nALL visible BSSIDs (includes random/virtual ones that may rotate):\n"
        s += "  FOUND_IN_NEARBY_BSSID([\(quoted(bssids))])\n"
        let savePath = (NSHomeDirectory() as NSString).appendingPathComponent("demonlock-bssids.txt")
        try? s.write(toFile: savePath, atomically: true, encoding: .utf8)
        s += "\n(saved to \(savePath))\n"
        emit(s)
        exit(0)
    }

    /// Write to stdout (if attached) AND to the live file so progress is observable either way.
    private func emit(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
        try? s.write(toFile: livePath, atomically: true, encoding: .utf8)
    }
}

func runScan() {
    // Must run as your user — root has no Location grant, so macOS redacts every BSSID.
    if geteuid() == 0 {
        FileHandle.standardError.write(Data("""
        ⚠️  Don't run scan with sudo. As root there's no Location grant (it belongs to your user),
            so macOS redacts every BSSID. Run it as yourself:   demonlock scan

        """.utf8))
        exit(1)
    }
    // Regular foreground app so the Location prompt surfaces clearly and attributes to Demonlock.
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)

    let controller = ScanController()

    // Ctrl+C → print the consolidated, paste-ready set, then exit.
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { controller.printFinalAndExit() }
    sigint.resume()

    controller.start()
    app.run()
}
