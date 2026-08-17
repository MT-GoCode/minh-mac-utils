import Foundation

/// Per-machine tunables, root-owned. Decoded leniently (a missing key falls back to its default)
/// so the file can evolve without breaking old installs.
struct Settings: Codable {
    var enforcedUser: String      // whose inbox markers the daemon will trust
    var pollSeconds: Double       // daemon tick
    var removeDelaySec: Double    // how long `remove` sits before it lands — the commitment device
    var graceSeconds: Double      // how late an occurrence may fire (covers a slow tick / brief downtime)

    init(enforcedUser: String = "", pollSeconds: Double = 5,
         removeDelaySec: Double = 12 * 3600, graceSeconds: Double = 120) {
        self.enforcedUser = enforcedUser
        self.pollSeconds = pollSeconds
        self.removeDelaySec = removeDelaySec
        self.graceSeconds = graceSeconds
    }

    init(from decoder: Decoder) throws {
        let d = Settings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enforcedUser   = (try? c.decode(String.self, forKey: .enforcedUser))   ?? d.enforcedUser
        pollSeconds    = (try? c.decode(Double.self, forKey: .pollSeconds))    ?? d.pollSeconds
        removeDelaySec = (try? c.decode(Double.self, forKey: .removeDelaySec)) ?? d.removeDelaySec
        graceSeconds   = (try? c.decode(Double.self, forKey: .graceSeconds))   ?? d.graceSeconds
    }

    static func load() -> Settings { loadJSON(Paths.settingsFile) ?? Settings() }

    /// Resolve enforcedUser (username or numeric uid string) to a uid. nil if unset/unknown.
    func enforcedUID() -> uid_t? {
        let v = enforcedUser.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return nil }
        if let n = UInt32(v) { return uid_t(n) }
        return v.withCString { cstr -> uid_t? in
            guard let pw = getpwnam(cstr) else { return nil }
            return pw.pointee.pw_uid
        }
    }
}

/// SignalWire credentials + the two endpoints of every call. Root-owned 600: collected once by the
/// installer from stdin so nothing secret is ever committed, and unreadable by you afterwards.
struct Creds: Codable {
    var space: String       // <you>.signalwire.com
    var projectId: String   // Basic-auth username
    var apiToken: String    // Basic-auth password
    var callerId: String    // what the far end sees (your verified number)
    var endpoint: String    // leg A — your SIP address, e.g. sip:me@minh.sip.signalwire.com

    static func load() -> Creds? { loadJSON(Paths.credsFile) }
}
