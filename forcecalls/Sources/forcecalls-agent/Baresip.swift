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

    @discardableResult
    static func command(_ cmd: String, timeout: Double = 1.0) -> String? {
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

        let json = "{\"command\":\"\(cmd)\"}"
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
