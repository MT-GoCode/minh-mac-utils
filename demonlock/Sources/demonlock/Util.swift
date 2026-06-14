import Foundation

/// Small process-running helpers used by the daemon, Wi-Fi control, and CLI.
enum Proc {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    static func capture(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

func nowEpoch() -> Double { Date().timeIntervalSince1970 }

/// Up, non-loopback, non-link-local IPv4 addresses (Wi-Fi/Ethernet) — for the "SSH in to disarm" hint.
func localIPv4s() -> [String] {
    var out: [String] = []
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0 else { return [] }
    defer { freeifaddrs(ifap) }
    var p = ifap
    while let cur = p {
        let ifa = cur.pointee
        if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
           (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254") { out.append(ip) }      // skip auto-assigned link-local
            }
        }
        p = ifa.ifa_next
    }
    return out
}

/// The Bonjour `LocalHostName` (e.g. "minhs-mac" → "minhs-mac.local"), a stable SSH target across IP
/// changes. Spawns scutil, so callers cache it (the name rarely changes).
func localBonjourName() -> String? {
    let n = Proc.capture("/usr/sbin/scutil", ["--get", "LocalHostName"]).trimmingCharacters(in: .whitespacesAndNewlines)
    return n.isEmpty ? nil : "\(n).local"
}

/// A BSSID is a stable hardware MAC (universally administered) when bit 0x02 of the first
/// octet is clear; otherwise it's locally-administered (random/virtual) and can rotate —
/// useless as a "same place" anchor.
func isStableBSSID(_ mac: String) -> Bool {
    guard let first = mac.split(separator: ":").first, let v = UInt8(first, radix: 16) else { return false }
    return (v & 0x02) == 0
}

/// "Am I still where the held fix was measured?" — true if ANY anchor AP is still visible.
/// We deliberately require only ONE overlap, not two: macOS hands a background agent sparse,
/// inconsistent scans (often just the associated router), so demanding ≥2 falsely reads "moved"
/// when you're sitting still and only 1 of your N anchor APs came back this scan — a false
/// lockout at home. Seeing even one of your anchor APs means you're in its range = here. (A lone
/// persistent/mobile AP fooling this — e.g. a train's own router — is corrected by the next
/// CoreLocation fix, per MODEL.md.) Empty anchor never confirms.
func bssidOverlapOK(anchor: [String], current: Set<String>) -> Bool {
    anchor.contains { current.contains($0) }
}
