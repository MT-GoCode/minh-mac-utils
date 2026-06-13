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
/// CoreLocation fix, per LOCATION-MODEL.md.) Empty anchor never confirms.
func bssidOverlapOK(anchor: [String], current: Set<String>) -> Bool {
    anchor.contains { current.contains($0) }
}
