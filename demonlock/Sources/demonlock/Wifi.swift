import Foundation

/// Root-side Wi-Fi control. The radio must be ON for CoreLocation positioning (and any
/// BSSID scan), so while armed the enforcer keeps it on — toggling it off just flips back.
enum Wifi {
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
