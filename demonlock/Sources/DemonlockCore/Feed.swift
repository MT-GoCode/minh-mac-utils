import Foundation
import Security

// MARK: - Peer trust (cdhash pinning)

/// Verifies that a connected socket peer is the *exact same signed binary* as us, by
/// checking the peer's kernel audit token against our own cdhash. Hardened runtime blocks
/// same-user code injection; the audit token (not PID) closes any TOCTOU window.
enum PeerTrust {
    private static let SOL_LOCAL: Int32 = 0
    private static let LOCAL_PEERTOKEN: Int32 = 0x006

    /// Fetch the connected peer's kernel audit token (unforgeable, not PID). nil on any error.
    static func peerToken(_ conn: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        let ok = withUnsafeMutablePointer(to: &token) {
            getsockopt(conn, SOL_LOCAL, LOCAL_PEERTOKEN, $0, &len)
        }
        guard ok == 0, len == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        return token
    }

    /// The peer's effective uid, straight from the audit token (XNU layout: val[1] = euid).
    static func euid(of token: audit_token_t) -> uid_t {
        withUnsafeBytes(of: token.val) { $0.load(fromByteOffset: MemoryLayout<UInt32>.size, as: UInt32.self) }
    }

    /// Is the peer the *exact same signed binary* as us (cdhash), by its audit token? Hardened runtime
    /// blocks same-user code injection; the audit token (not PID) closes any TOCTOU window.
    static func isTrusted(token: audit_token_t, requirement: SecRequirement?) -> Bool {
        guard let requirement else { return false }
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

    /// Forget the last payload (called on console-session change) so a new session starts with
    /// a genuinely empty feed rather than inheriting a dead session's last packet.
    func clear() { lock.lock(); _latest = nil; lock.unlock() }

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
            // Trust the peer only if (1) it's our exact signed binary (cdhash) AND (2) it runs as the
            // ENFORCED user. The euid pin closes the second-GUI-session bypass: a Guest/other account's
            // agent has the same cdhash but a different euid, so its packets — which carry the WRONG
            // session's guiPids — are refused. [review H1 / finding A]
            guard let token = PeerTrust.peerToken(conn),
                  PeerTrust.isTrusted(token: token, requirement: requirement),
                  peerUIDAllowed(PeerTrust.euid(of: token))
            else { close(conn); continue }
            Thread.detachNewThread { [weak self] in self?.handle(conn) }
        }
    }

    /// Accept a feed only from the enforced user (or from anyone pre-config, when there's nothing to
    /// enforce yet — cdhash still gates it to our binary).
    private func peerUIDAllowed(_ euid: uid_t) -> Bool {
        guard let enforced = Settings.load().enforcedUID() else { return true }
        return euid == enforced
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
        // write() may return a SHORT count (send buffer full); loop until the whole line is out,
        // else a truncated line breaks the server's newline framing and the feed silently stalls.
        let ok = data.withUnsafeBytes { raw -> Bool in
            guard var ptr = raw.baseAddress else { return false }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n <= 0 { return false }
                ptr = ptr.advanced(by: n); remaining -= n
            }
            return true
        }
        if !ok { close(fd); fd = -1 }     // drop & reconnect next time
    }
}
