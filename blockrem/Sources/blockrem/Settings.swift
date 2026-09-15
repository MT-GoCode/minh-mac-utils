import Foundation
import MacUtilsCore

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
        enforcedUser = c.lenient(.enforcedUser, default: d.enforcedUser)
        pollSeconds  = c.lenient(.pollSeconds, default: d.pollSeconds)
    }

    static func load() -> Settings { loadJSON(Paths.settingsFile) ?? Settings() }

    /// Resolve enforcedUser (username or numeric uid string) to a uid. nil if unset/unknown.
    func enforcedUID() -> uid_t? { resolveUID(enforcedUser) }
}
