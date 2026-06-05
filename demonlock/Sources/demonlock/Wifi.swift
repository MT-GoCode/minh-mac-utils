import Foundation

/// Root-side Wi-Fi control. The radio must be ON for CoreLocation positioning (and any
/// BSSID scan), so while armed the enforcer keeps it on — toggling it off just flips back.
enum Wifi {
    /// Detect the Wi-Fi BSD device (e.g. en0) from `networksetup -listallhardwareports`.
    static func detectDevice() -> String {
        let out = Proc.capture("/usr/sbin/networksetup", ["-listallhardwareports"])
        let lines = out.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where line.contains("Wi-Fi") {
            for j in i..<min(i + 3, lines.count) where lines[j].hasPrefix("Device:") {
                return lines[j].dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return "en0"
    }

    static func isOn(_ device: String) -> Bool {
        Proc.capture("/usr/sbin/networksetup", ["-getairportpower", device]).contains("On")
    }

    /// Ensure the radio is on; returns true if it was already on (no action needed).
    @discardableResult
    static func ensureOn(_ device: String) -> Bool {
        if isOn(device) { return true }
        Proc.run("/usr/sbin/networksetup", ["-setairportpower", device, "on"])
        return false
    }
}
