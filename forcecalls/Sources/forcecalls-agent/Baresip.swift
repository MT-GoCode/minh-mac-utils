import Foundation

/// Talk to the local baresip over its `ctrl_tcp` module: JSON commands wrapped in netstrings on
/// 127.0.0.1:4444. Synchronous with a hard timeout — this runs on a 2s UI timer, so a hung socket
/// must never wedge the main thread.
enum Baresip {

    static let port: UInt16 = 4444

    /// True when baresip has a call up. Because forcecalls dials the DESTINATION first and only
    /// bridges to this endpoint once they answer, an established call here means — always, by
    /// construction — that the other person has picked up. That is the whole exposure rule.
    static func callIsLive() -> Bool {
        guard let reply = command("listcalls") else { return false }
        return reply.uppercased().contains("ESTABLISHED")
    }

    /// ctrl_tcp rejected our frames with ENOTSUP and logged an error per poll, which filled
    /// /var/log/baresip.log with one line every 2s. Two changes: send the full documented message
    /// shape (params + token, not just command), and stop hammering after repeated failures — a
    /// status indicator is never worth spamming a log we don't own.
    private static var consecutiveFailures = 0
    private static var skipped = 0
    private static let failureCeiling = 5
    private static let slowRetryEvery = 30      // ~1 minute at the 2s poll

    @discardableResult
    static func command(_ cmd: String, timeout: Double = 1.0) -> String? {
        // Back off to an occasional retry rather than giving up for good: if ctrl_tcp comes back
        // (baresip restarted, config fixed), the indicator should heal itself without a relaunch.
        if consecutiveFailures >= failureCeiling {
            skipped += 1
            if skipped < slowRetryEvery { return nil }
            skipped = 0
        }
        let r = exchange(cmd, timeout: timeout)
        consecutiveFailures = (r == nil) ? consecutiveFailures + 1 : 0
        return r
    }

    /// Clear the back-off — call when the user asks for something explicitly, so a transient
    /// failure doesn't disable the control channel until the next launch.
    static func resetBackoff() { consecutiveFailures = 0; skipped = 0 }

    private static func exchange(_ cmd: String, timeout: Double) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { return nil }

        // Full documented shape: bare {"command":…} came back as ENOTSUP.
        let json = "{\"command\":\"\(cmd)\",\"params\":\"\",\"token\":\"fc\"}"
        let frame = "\(json.utf8.count):\(json),"     // netstring framing, per ctrl_tcp
        let wrote: Int = Array(frame.utf8).withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return -1 }
            return send(fd, base, buf.count, 0)
        }
        guard wrote > 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        return String(bytes: buf[0..<n], encoding: .utf8)
    }
}
