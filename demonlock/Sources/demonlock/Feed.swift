import Foundation
import Security

// MARK: - Peer trust (cdhash pinning)

/// Verifies that a connected socket peer is the *exact same signed binary* as us, by
/// checking the peer's kernel audit token against our own cdhash. Hardened runtime blocks
/// same-user code injection; the audit token (not PID) closes any TOCTOU window.
enum PeerTrust {
    private static let SOL_LOCAL: Int32 = 0
    private static let LOCAL_PEERTOKEN: Int32 = 0x006

    static func isTrusted(_ conn: Int32, requirement: SecRequirement?) -> Bool {
        guard let requirement else { return false }
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        let ok = withUnsafeMutablePointer(to: &token) {
            getsockopt(conn, SOL_LOCAL, LOCAL_PEERTOKEN, $0, &len)
        }
        guard ok == 0, len == socklen_t(MemoryLayout<audit_token_t>.size) else { return false }

        let tokenData = withUnsafeBytes(of: token) { Data($0) } as CFData
        let attrs = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &guest) == errSecSuccess, let g = guest
        else { return false }
        return SecCodeCheckValidity(g, [], requirement) == errSecSuccess
    }

    /// A `cdhash H"..."` requirement built from our own running code, so server and client
    /// (the same Mach-O invoked as `enforcerd` vs `agent`) share an identical requirement.
    static func selfRequirement() -> SecRequirement? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var stat: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &stat) == errSecSuccess, let stat else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(stat, SecCSFlags(rawValue: 0), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let cdhash = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        let hex = cdhash.map { String(format: "%02x", $0) }.joined()
        var req: SecRequirement?
        guard SecRequirementCreateWithString("cdhash H\"\(hex)\"" as CFString, [], &req) == errSecSuccess
        else { return nil }
        return req
    }
}

// MARK: - sockaddr_un helper

private func makeUnixAddr(_ path: String) -> (sockaddr_un, socklen_t) {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    let cap = MemoryLayout.size(ofValue: addr.sun_path)   // capture before exclusive access
    withUnsafeMutablePointer(to: &addr.sun_path) { raw in
        raw.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
            for i in 0..<min(bytes.count, cap - 1) { dst[i] = bytes[i] }
        }
    }
    return (addr, socklen_t(MemoryLayout<sockaddr_un>.size))
}

// MARK: - Server (root enforcer)

/// Listens on the trusted socket, accepts only cdhash-matching peers, and keeps the most
/// recent FeedPayload (with its arrival time so the daemon can judge freshness).
final class SecureFeedServer {
    private let lock = NSLock()
    private var _latest: (payload: FeedPayload, at: Date)?
    private let requirement = PeerTrust.selfRequirement()

    func latest() -> (payload: FeedPayload, at: Date)? {
        lock.lock(); defer { lock.unlock() }; return _latest
    }

    func start() {
        Thread.detachNewThread { [weak self] in self?.serve() }
    }

    private func serve() {
        unlink(Paths.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("demonlock: socket() failed"); return }
        var (addr, len) = makeUnixAddr(Paths.socketPath)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { NSLog("demonlock: bind() failed"); close(fd); return }
        chmod(Paths.socketPath, 0o666)              // identity is verified, not access-gated
        guard listen(fd, 8) == 0 else { NSLog("demonlock: listen() failed"); close(fd); return }

        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 { continue }
            guard PeerTrust.isTrusted(conn, requirement: requirement) else { close(conn); continue }
            Thread.detachNewThread { [weak self] in self?.handle(conn) }
        }
    }

    private func handle(_ conn: Int32) {
        defer { close(conn) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(conn, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {           // split on '\n'
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let p = try? JSONDecoder().decode(FeedPayload.self, from: line) {
                    lock.lock(); _latest = (p, Date()); lock.unlock()
                }
            }
        }
    }
}

// MARK: - Sender (agent)

/// Connects to the trusted socket and sends one JSON line per payload, reconnecting as needed.
final class FeedSender {
    private var fd: Int32 = -1
    private let encoder = JSONEncoder()

    private func connectIfNeeded() {
        guard fd < 0 else { return }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var (addr, len) = makeUnixAddr(Paths.socketPath)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, len) }
        }
        if ok == 0 { fd = s } else { close(s) }
    }

    func send(_ payload: FeedPayload) {
        connectIfNeeded()
        guard fd >= 0, var data = try? encoder.encode(payload) else { return }
        data.append(0x0A)
        let wrote = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        if wrote <= 0 { close(fd); fd = -1 }     // drop & reconnect next time
    }
}
