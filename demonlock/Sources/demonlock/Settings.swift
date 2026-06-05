import Foundation

/// Tunables, persisted as root-owned settings.json. Every field has a default and is
/// decoded leniently (a missing key falls back to its default) so the file can evolve.
struct Settings: Codable {
    var pollSeconds: Double            // steady enforcer tick (first check immediate)
    var countdownPollSeconds: Double   // faster re-eval while a countdown is active
    var countdownSeconds: Double       // the one visible countdown, used for every block
    var snoozeHHMM: String             // snoozetonight target time of day (HHMM)
    var staleSeconds: Double           // feed older than this ⇒ agent considered not-reporting
    var scanSeconds: Double            // CoreWLAN rescan cadence
    var initMaxSeconds: Double         // bound on warm-up grace for an indeterminate verdict
    var enforcedUser: String           // username OR numeric uid this policy applies to
    var wifiKeepOn: Bool               // keep the Wi-Fi radio on at check time (location needs it)
    var wifiDevice: String             // BSD Wi-Fi device, e.g. en0

    init(pollSeconds: Double = 1.0, countdownPollSeconds: Double = 0.5, countdownSeconds: Double = 10,
         snoozeHHMM: String = "0500", staleSeconds: Double = 30, scanSeconds: Double = 20,
         initMaxSeconds: Double = 90, enforcedUser: String = "", wifiKeepOn: Bool = true,
         wifiDevice: String = "en0") {
        self.pollSeconds = pollSeconds; self.countdownPollSeconds = countdownPollSeconds
        self.countdownSeconds = countdownSeconds; self.snoozeHHMM = snoozeHHMM
        self.staleSeconds = staleSeconds; self.scanSeconds = scanSeconds
        self.initMaxSeconds = initMaxSeconds; self.enforcedUser = enforcedUser
        self.wifiKeepOn = wifiKeepOn; self.wifiDevice = wifiDevice
    }

    init(from decoder: Decoder) throws {
        let d = Settings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pollSeconds          = (try? c.decode(Double.self, forKey: .pollSeconds)) ?? d.pollSeconds
        countdownPollSeconds = (try? c.decode(Double.self, forKey: .countdownPollSeconds)) ?? d.countdownPollSeconds
        countdownSeconds     = (try? c.decode(Double.self, forKey: .countdownSeconds)) ?? d.countdownSeconds
        snoozeHHMM           = (try? c.decode(String.self, forKey: .snoozeHHMM)) ?? d.snoozeHHMM
        staleSeconds         = (try? c.decode(Double.self, forKey: .staleSeconds)) ?? d.staleSeconds
        scanSeconds          = (try? c.decode(Double.self, forKey: .scanSeconds)) ?? d.scanSeconds
        initMaxSeconds       = (try? c.decode(Double.self, forKey: .initMaxSeconds)) ?? d.initMaxSeconds
        enforcedUser         = (try? c.decode(String.self, forKey: .enforcedUser)) ?? d.enforcedUser
        wifiKeepOn           = (try? c.decode(Bool.self,   forKey: .wifiKeepOn)) ?? d.wifiKeepOn
        wifiDevice           = (try? c.decode(String.self, forKey: .wifiDevice)) ?? d.wifiDevice
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.settingsFile)),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    func save(to path: String = Paths.settingsFile) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
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
