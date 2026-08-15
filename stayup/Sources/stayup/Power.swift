import Foundation
import IOKit.ps

// The one piece of real state: macOS's SleepDisabled power setting. Unlike caffeinate /
// Amphetamine assertions (which only defeat idle sleep and die with the process),
// `pmset -a disablesleep` keeps the machine fully awake WITH THE LID CLOSED and persists
// across reboots — so it must be read from the system, never remembered in the app.
enum Power {
    /// Is lid-closed-awake currently on? `IOPMCopySystemPowerSettings` isn't bridged into
    /// Swift, so this reads pmset — the same source the `stayup` CLI has always used.
    /// Always the SYSTEM's answer, never a value this app remembered.
    static var sleepDisabled: Bool {
        shell("/usr/bin/pmset", ["-g"])
            .range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    /// Flip it. Needs the /etc/sudoers.d/stayup NOPASSWD rule the installer writes;
    /// returns false (with the reason) if that's missing rather than hanging on a prompt.
    @discardableResult
    static func setSleepDisabled(_ on: Bool) -> (ok: Bool, message: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do { try p.run() } catch { return (false, "couldn't run pmset: \(error.localizedDescription)") }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return (true, "") }
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if msg.contains("password is required") || msg.contains("a terminal is required") {
            return (false, "passwordless pmset rule missing — run: sudo ./install.sh")
        }
        return (false, msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    struct Battery {
        var onAC: Bool
        var percent: Int?
    }

    static var battery: Battery {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef]
        else { return Battery(onAC: true, percent: nil) }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(snap, src)?.takeUnretainedValue()
                as? [String: Any] else { continue }
            let state = d[kIOPSPowerSourceStateKey] as? String
            var pct: Int?
            if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int,
               max > 0 { pct = Int((Double(cur) / Double(max)) * 100) }
            return Battery(onAC: state == kIOPSACPowerValue, percent: pct)
        }
        return Battery(onAC: true, percent: nil)   // desktop / no battery
    }

    static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }
}
