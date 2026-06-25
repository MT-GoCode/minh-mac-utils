import Foundation

/// Tunables, persisted as root-owned settings.json. Every field has a default and is
/// decoded leniently (a missing key falls back to its default) so the file can evolve.
struct Settings: Codable {
    var pollSeconds: Double            // steady enforcer tick (first check immediate)
    var countdownPollSeconds: Double   // faster re-eval while a countdown is active
    var countdownSeconds: Double       // THE buffer: the one visible countdown before lockout, for EVERY block
                                       // (out of policy, can't determine, agent reconnecting on wake). Re-
                                       // evaluated each tick — cancels the instant you're provably in policy.
    var snoozeHHMM: String             // snoozetonight target time of day (HHMM)
    var graceSeconds: Double           // location-confidence coast: the held fix stays LIVE this long after the
                                       // last CONFIRMATION (a new fix, or the anchor still overlapping the live
                                       // scan). Anything that doesn't confirm — Wi-Fi off, anchor mismatch,
                                       // agent dead, agent starting, just-woke — lets it run out → STALE →
                                       // fail-closed. One timer for every "no signal" case. See MODEL.md.
    var maxAccuracyMeters: Double      // a fix fuzzier than this is not adopted. Macs are Wi-Fi-only
                                       // (±60–100m stationary urban, but a few hundred m on a moving
                                       // vehicle / in sparse-AP stretches — e.g. Caltrain), so keep it
                                       // GENEROUS: accuracy only matters vs zone size, and big zones (a
                                       // whole metro) tolerate fuzzy fixes while small zones sit in dense
                                       // Wi-Fi and get good accuracy anyway. Lower it only if you rely on
                                       // tight zones in sparse areas. (Still rejects km-scale garbage.)
    var scanSeconds: Double            // full scanForNetworks cadence (CoreWLAN floor ~4s). The agent ALSO
                                       // samples the associated-AP BSSID every ~2s between full scans, so the
                                       // live band is always current; this is just the all-bands sweep rate.
    var scanWindowSeconds: Double      // rolling-log window: the agent reports the UNION of every BSSID seen in
                                       // the last this-many seconds (ages out, NOT cleared on Wi-Fi off). An
                                       // EMPTY window = positive signal-loss (the associated-AP read would give
                                       // ≥1 BSSID if joined), so it stops confirming the fix → grace → lock.
    var enforcedUser: String           // username OR numeric uid this policy applies to
    var wifiKeepOn: Bool               // keep the Wi-Fi radio on at check time (location needs it)
    var wifiDevice: String             // BSD Wi-Fi device, e.g. en0
    var spareBundleIDs: [String]       // bundle IDs NEVER force-killed during a lockout. The LOCKED kill now
                                       // covers EVERY .regular app PLUS non-Apple .accessory (menubar) apps —
                                       // so an LSUIElement distraction can't hide — which means persistent
                                       // menubar utilities that break when SIGKILLed must be listed here.
                                       // Apple's own menubar items (com.apple.* — Wi-Fi/battery/Control Center,
                                       // Spotlight, Siri) are spared automatically; pure daemons (no GUI app)
                                       // are never in the kill-list. The agent reloads this each feed, so
                                       // editing settings.json takes effect live. NOTE: spares only the per-app
                                       // kill; the agent-dead NUCLEAR `killall -9 WindowServer` takes ALL GUI.

    init(pollSeconds: Double = 1.0, countdownPollSeconds: Double = 0.5, countdownSeconds: Double = 10,
         snoozeHHMM: String = "0500", graceSeconds: Double = 90,
         maxAccuracyMeters: Double = 400, scanSeconds: Double = 6, scanWindowSeconds: Double = 30,
         enforcedUser: String = "", wifiKeepOn: Bool = true, wifiDevice: String = "en0",
         spareBundleIDs: [String] = [
            "com.demonlock",                       // own .regular windows (zones/scan/disarm); agent also spared by PID
            "com.blockrem",                        // the break-blocker sibling tool — keep it shielding
            "com.lwouis.alt-tab-macos",            // AltTab
            "com.raycast.macos",                   // Raycast (menubar launcher)
            "cc.ffitch.shottr",                    // Shottr (screenshot tool)
            "com.pilotmoon.scroll-reverser",       // Scroll Reverser
            "pro.betterdisplay.BetterDisplay",     // BetterDisplay
            "com.wtalk.daemon",                    // wtalk
            "org.pqrs.Karabiner-Core-Service",     // Karabiner-Elements (runs as several processes)
            "org.pqrs.Karabiner-Menu",
            "org.pqrs.Karabiner-NotificationWindow",
         ]) {  // persistent menubar utilities to keep alive through a lockout. Apple's com.apple.* menubar
               // items (Wi-Fi/battery/Control Center) are spared automatically; pure daemons (betterat,
               // nextdns*) have no GUI app and are never killed. Add your own by editing settings.json.
        self.pollSeconds = pollSeconds; self.countdownPollSeconds = countdownPollSeconds
        self.countdownSeconds = countdownSeconds; self.snoozeHHMM = snoozeHHMM
        self.graceSeconds = graceSeconds
        self.maxAccuracyMeters = maxAccuracyMeters; self.scanSeconds = scanSeconds
        self.scanWindowSeconds = scanWindowSeconds; self.enforcedUser = enforcedUser
        self.wifiKeepOn = wifiKeepOn; self.wifiDevice = wifiDevice
        self.spareBundleIDs = spareBundleIDs
    }

    init(from decoder: Decoder) throws {
        let d = Settings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pollSeconds          = (try? c.decode(Double.self, forKey: .pollSeconds)) ?? d.pollSeconds
        countdownPollSeconds = (try? c.decode(Double.self, forKey: .countdownPollSeconds)) ?? d.countdownPollSeconds
        countdownSeconds     = (try? c.decode(Double.self, forKey: .countdownSeconds)) ?? d.countdownSeconds
        snoozeHHMM           = (try? c.decode(String.self, forKey: .snoozeHHMM)) ?? d.snoozeHHMM
        graceSeconds         = (try? c.decode(Double.self, forKey: .graceSeconds)) ?? d.graceSeconds
        maxAccuracyMeters    = (try? c.decode(Double.self, forKey: .maxAccuracyMeters)) ?? d.maxAccuracyMeters
        scanSeconds          = (try? c.decode(Double.self, forKey: .scanSeconds)) ?? d.scanSeconds
        scanWindowSeconds    = (try? c.decode(Double.self, forKey: .scanWindowSeconds)) ?? d.scanWindowSeconds
        enforcedUser         = (try? c.decode(String.self, forKey: .enforcedUser)) ?? d.enforcedUser
        wifiKeepOn           = (try? c.decode(Bool.self,   forKey: .wifiKeepOn)) ?? d.wifiKeepOn
        wifiDevice           = (try? c.decode(String.self, forKey: .wifiDevice)) ?? d.wifiDevice
        spareBundleIDs       = (try? c.decode([String].self, forKey: .spareBundleIDs)) ?? d.spareBundleIDs
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
