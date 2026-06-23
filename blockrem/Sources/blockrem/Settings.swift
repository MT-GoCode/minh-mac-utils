import Foundation

/// Per-machine tunables, persisted as root-owned settings.json. Decoded leniently (a missing
/// key falls back to its default) so the file can evolve without breaking old installs.
struct Settings: Codable {
    var enforcedUser: String   // username OR numeric uid this blocker applies to (the console session it guards)
    var pollSeconds: Double    // root daemon tick (active-block evaluation cadence)

    init(enforcedUser: String = "", pollSeconds: Double = 1.0) {
        self.enforcedUser = enforcedUser
        self.pollSeconds = pollSeconds
    }

    init(from decoder: Decoder) throws {
        let d = Settings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enforcedUser = (try? c.decode(String.self, forKey: .enforcedUser)) ?? d.enforcedUser
        pollSeconds  = (try? c.decode(Double.self, forKey: .pollSeconds)) ?? d.pollSeconds
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.settingsFile)),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

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
