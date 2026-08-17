import Foundation

/// "Is Minh actually at the machine right now?"
///
/// Not a PID check — a process being alive says nothing about whether anyone touched the keyboard.
/// macOS answers this directly: the IOHIDSystem registry entry carries `HIDIdleTime`, nanoseconds
/// since the last keyboard or mouse input. Combined with the console user, that's presence.
///
/// Deliberately fails CLOSED for the *call*: if idle time can't be read, we do NOT dial. A forced
/// call that fires into an empty room rings the other person for nothing, and the whole point is
/// that they only get called when you're there to talk.
enum Presence {

    struct Verdict {
        var present: Bool
        var reason: String       // human, for the log and `forcecalls show`
        var idleSeconds: Double?
        var consoleUser: String?
    }

    /// Who is logged in at the physical screen. nil at the login window.
    static func consoleUser() -> String? {
        var st = stat()
        guard stat("/dev/console", &st) == 0 else { return nil }
        guard let pw = getpwuid(st.st_uid) else { return nil }
        let name = String(cString: pw.pointee.pw_name)
        return name.isEmpty || name == "root" ? nil : name
    }

    /// Seconds since the last HID input, or nil if it can't be determined.
    static func idleSeconds() -> Double? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-c", "IOHIDSystem", "-d", "4", "-r"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }

        // Lines look like:  "HIDIdleTime" = 4823117000
        guard let range = out.range(of: "\"HIDIdleTime\" = ") else { return nil }
        let tail = out[range.upperBound...].prefix(while: { $0.isNumber })
        guard let nanos = Double(tail) else { return nil }
        return nanos / 1_000_000_000
    }

    /// `maxIdle <= 0` disables the check entirely — always present.
    static func check(enforcedUser: String, maxIdle: Double) -> Verdict {
        guard maxIdle > 0 else {
            return Verdict(present: true, reason: "presence check disabled", idleSeconds: nil, consoleUser: nil)
        }
        let who = consoleUser()
        guard let who else {
            return Verdict(present: false, reason: "nobody logged in at the screen", idleSeconds: nil, consoleUser: nil)
        }
        guard who == enforcedUser else {
            return Verdict(present: false, reason: "'\(who)' is at the screen, not '\(enforcedUser)'",
                           idleSeconds: nil, consoleUser: who)
        }
        guard let idle = idleSeconds() else {
            return Verdict(present: false, reason: "couldn't read idle time — not dialling",
                           idleSeconds: nil, consoleUser: who)
        }
        if idle > maxIdle {
            return Verdict(present: false, reason: "idle \(fmtLeft(idle)) (limit \(fmtLeft(maxIdle)))",
                           idleSeconds: idle, consoleUser: who)
        }
        return Verdict(present: true, reason: "active \(fmtLeft(idle)) ago", idleSeconds: idle, consoleUser: who)
    }
}
