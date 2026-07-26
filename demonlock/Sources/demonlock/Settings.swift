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
    var spareApps: [String: String]    // bundleID → expected TEAM ID. An app is spared from the lockout
                                       // kill ONLY if it's listed here AND its live code signature satisfies
                                       // "anchor apple generic + that Team ID + that identifier" — so a
                                       // distraction that merely spoofs a whitelisted bundle id in its
                                       // Info.plist is still killed. Team ID (not cdhash) so the spare
                                       // survives app auto-updates. The LOCKED kill covers EVERY .regular app
                                       // PLUS non-Apple .accessory (menubar) apps; Apple's own com.apple.*
                                       // menubar items are spared automatically; pure daemons (no GUI app) are
                                       // never in the kill-list. Reloaded each feed (edit settings.json live).
                                       // NOTE: spares only the per-app kill; the agent-dead NUCLEAR
                                       // `killall -9 WindowServer` takes ALL GUI regardless.

    init(pollSeconds: Double = 1.0, countdownPollSeconds: Double = 0.5, countdownSeconds: Double = 10,
         snoozeHHMM: String = "0500", graceSeconds: Double = 90,
         maxAccuracyMeters: Double = 400, scanSeconds: Double = 6, scanWindowSeconds: Double = 30,
         enforcedUser: String = "", wifiKeepOn: Bool = true, wifiDevice: String = "en0",
         spareApps: [String: String] = [
            // Our own (team BULCQM9J2V) apps are only safe here because spareVerified additionally
            // requires a ROOT-OWNED bundle for self-team apps — demonlock, wtalk, blockrem,
            // foreman-uplink, and multistreamviewer all install to /Applications root:wheel, so you
            // can't swap them for a browser without sudo, and a sibling app you re-sign with your own
            // Team ID (in ~/Applications) fails the owner check. wtalk is additionally a FROZEN binary
            // (PyInstaller bootloader, not a `python` CLI) so it can't be redirected to run arbitrary
            // code — a plain Python .app could be. A self-team entry not actually root-owned installed
            // just never spares (owner check fails), it doesn't get any looser exception. Third-party
            // entries below need no owner check — you can't re-sign as their teams.
            "com.demonlock":                        "BULCQM9J2V",   // the enforcer itself (root-owned install)
            "com.wtalk.daemon":                     "BULCQM9J2V",   // wtalk dictation (frozen, root-owned install)
            "com.blockrem":                         "BULCQM9J2V",   // blockrem break-blocker (root-owned install)
            "com.minh.remote-agent-connector":      "BULCQM9J2V",   // Remote Agent Connector (foreman-uplink successor; .regular dock app, root-owned install)
            "com.minh.multistreamviewer":           "BULCQM9J2V",   // MultiStreamViewer
            "com.lwouis.alt-tab-macos":             "QXD7GW8FHY",   // AltTab
            "com.raycast.macos":                    "SY64MV22J9",   // Raycast (menubar launcher)
            "cc.ffitch.shottr":                     "2Y683PRQWN",   // Shottr (screenshot tool)
            "com.if.Amphetamine":                   "U5SR49N3PT",   // Amphetamine (keep-awake)
            "pro.betterdisplay.BetterDisplay":      "299YSU96J7",   // BetterDisplay
            "com.pilotmoon.scroll-reverser":        "6W6K75YWQ9",   // Scroll Reverser
            "org.pqrs.Karabiner-Core-Service":      "G43BCU2T37",   // Karabiner-Elements (several processes)
            "org.pqrs.Karabiner-Menu":              "G43BCU2T37",
            "org.pqrs.Karabiner-NotificationWindow":"G43BCU2T37",
         ]) {  // persistent menubar utilities to keep alive through a lockout, each PINNED to its signer's
               // Team ID (a spoofed bundle id from another signer is still killed). Add your own as
               // "bundle.id": "TEAMID" (get the team via `codesign -dv --verbose=4 /path/App.app`).
        self.pollSeconds = pollSeconds; self.countdownPollSeconds = countdownPollSeconds
        self.countdownSeconds = countdownSeconds; self.snoozeHHMM = snoozeHHMM
        self.graceSeconds = graceSeconds
        self.maxAccuracyMeters = maxAccuracyMeters; self.scanSeconds = scanSeconds
        self.scanWindowSeconds = scanWindowSeconds; self.enforcedUser = enforcedUser
        self.wifiKeepOn = wifiKeepOn; self.wifiDevice = wifiDevice
        self.spareApps = spareApps
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
        spareApps            = (try? c.decode([String: String].self, forKey: .spareApps)) ?? d.spareApps
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
