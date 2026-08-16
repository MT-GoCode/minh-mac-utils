import Foundation

/// BAKED bounds — compiled into the binary, never read from any file. These are the FLOORS/CEILINGS
/// of the no-sudo commitment delays: they are the whole point of the design, so they must not be
/// editable through the same silent channel (a root settings.json edit) the delays are meant to
/// resist. A root user CAN still change the per-slot delay VALUE (via `set-delay`), but every use
/// clamps that value into these ranges, so neither a stale file nor a settings edit can push a no-sudo
/// delay below its floor. If you want to change a floor, you must recompile — which is not silent.
enum Bounds {
    static let policyDelay          = 12.0 * 3600 ... 168.0 * 3600   // delay-set-policy
    static let zonesDelay           = 12.0 * 3600 ... 168.0 * 3600   // delayed zone add/delete
    static let gatePolicyDelay      = 12.0 * 3600 ... 168.0 * 3600   // release-valve delay-set-gate-policy
    static let safeAppsDelay        =  8.0 * 3600 ... 168.0 * 3600   // safe-apps delayed-register
    static let snoozePresetAddDelay = 24.0 * 3600 ... 168.0 * 3600   // snooze-preset delayed-add
    static let snoozePresetInvokeDelay = 1.0 * 3600 ... 168.0 * 3600 // a preset's invoke delay
    static let snoozeDurationMax    = 18.0 * 3600                    // any snooze / preset duration ceiling
    static let rvRequestDelayMin    = 30.0 * 60                      // release-valve request delay floor
    static let rvMaxRequestDurationCeil = 4.0 * 3600                 // ceiling on the configurable grant duration
    static let rvExtendMax          = 1.0 * 3600                     // i-still-need-sudo: ≤ this per call
    static let lockboxUnlockDelayMin = 1.0 * 3600                    // password-lockbox per-entry unlock delay floor
    static let lockboxAutoRelock    = 15.0 * 60                      // auto-relock an unlocked, never-copied secret

    static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { Swift.min(Swift.max(v, r.lowerBound), r.upperBound) }
}

/// Tunables, persisted as root-owned settings.json. Every field has a default and is decoded leniently
/// (a missing key falls back to its default) so the file can evolve. Root-WRITABLE only (mode 644): the
/// user agent + status CLI must READ it (kill list, sensor config), so it can't be 600.
struct Settings: Codable {
    // ── enforcement cadence ────────────────────────────────────────────────────────────────────
    var pollSeconds: Double            // steady enforcer tick (first check immediate)
    var countdownPollSeconds: Double   // faster re-eval while a countdown is active
    var countdownSeconds: Double       // THE buffer: the one visible countdown before lockout, for EVERY block
                                       // (out of policy, can't determine, agent reconnecting on wake). Re-
                                       // evaluated each tick — cancels the instant you're provably in policy.
    var agentRefreshSeconds: Double    // agent UI/status refresh timer

    // ── location model ─────────────────────────────────────────────────────────────────────────
    var graceSeconds: Double           // location-confidence coast after the last CONFIRMATION (new fix, or
                                       // anchor overlap). Anything that doesn't confirm lets it run out →
                                       // STALE → fail-closed. One timer for every "no signal" case (MODEL.md).
    var maxAccuracyMeters: Double      // a fix fuzzier than this is not adopted (generous — Macs are Wi-Fi-only).
    var scanSeconds: Double            // full scanForNetworks cadence (CoreWLAN floor ~4s).
    var scanWindowSeconds: Double      // rolling-log window: agent reports the UNION of BSSIDs seen in the last
                                       // this-many seconds. Empty window = positive signal-loss → stops confirming.
    var scanSlackSeconds: Double       // delivery-slack backstop on scan freshness (agent already prunes).
    var materialChangeDeg: Double      // held-fix persist threshold (~°lat/lon) — a moving vehicle must not
                                       // rewrite heldfix.json every fix, nor a bare confirmedUntil bump.

    // ── liveness / recovery watchdog ───────────────────────────────────────────────────────────
    var feedFreshSeconds: Double       // no agent packet within this ⇒ agent considered dead
    var agentGraceSeconds: Double      // startup/recovery grace: an agent silent for LESS than this is
                                       // "starting/blip" — no kickstart, no nuclear kill (never nuke a normal login).
    var agentKickSeconds: Double       // force-restart a wedged-but-alive agent at most this often
    var nuclearRelockSeconds: Double   // WindowServer-kill cadence when the agent is dead (long enough for
                                       // KeepAlive to relaunch + report; short enough not to buy free GUI)
    var heldPersistSeconds: Double     // re-persist a confirmed fix at least this often (reboot reads a live timer)

    // ── identity / radio ───────────────────────────────────────────────────────────────────────
    var enforcedUser: String           // username OR numeric uid this policy applies to
    var wifiKeepOn: Bool               // keep the Wi-Fi radio on at check time (location needs it)
    var wifiDevice: String             // BSD Wi-Fi device, e.g. en0
    var snoozeHHMM: String             // snoozetonight target time of day (HHMM) — legacy, snooze-presets supersede

    // ── configurable commitment delays (seconds) — clamped by Bounds at every use ───────────────
    var policyDelaySec: Double         // delay-set-policy landing delay
    var zonesDelaySec: Double          // delayed zone add/delete landing delay
    var gatePolicyDelaySec: Double     // release-valve delay-set-gate-policy landing delay
    var safeAppsDelaySec: Double       // safe-apps delayed-register landing delay
    var snoozePresetAddDelaySec: Double// snooze-preset delayed-add landing delay

    // safe-apps: user-managed spare list layered over SafeApps.defaults. `safeAppsUser` are additions
    // (by bid, they override a default); `safeAppsRemoved` are bids tombstoned out of the defaults
    // (never com.demonlock). The effective list is SafeApps.effective(). Reloaded each feed. NOTE: spares
    // only the per-app kill; the agent-dead NUCLEAR `killall -9 WindowServer` takes ALL GUI regardless.
    var safeAppsUser: [SafeApp]
    var safeAppsRemoved: [String]
    // snooze-presets: user-managed named snooze shortcuts layered over SnoozePresets.defaults.
    var snoozePresetsUser: [SnoozePreset]
    var snoozePresetsRemoved: [String]

    init(pollSeconds: Double = 1.0, countdownPollSeconds: Double = 0.5, countdownSeconds: Double = 10,
         agentRefreshSeconds: Double = 0.25,
         graceSeconds: Double = 90, maxAccuracyMeters: Double = 400, scanSeconds: Double = 6,
         scanWindowSeconds: Double = 30, scanSlackSeconds: Double = 10, materialChangeDeg: Double = 2.5e-4,
         feedFreshSeconds: Double = 5, agentGraceSeconds: Double = 25, agentKickSeconds: Double = 30,
         nuclearRelockSeconds: Double = 15, heldPersistSeconds: Double = 30,
         enforcedUser: String = "", wifiKeepOn: Bool = true, wifiDevice: String = "en0", snoozeHHMM: String = "0500",
         policyDelaySec: Double = 36 * 3600, zonesDelaySec: Double = 36 * 3600,
         gatePolicyDelaySec: Double = 36 * 3600, safeAppsDelaySec: Double = 24 * 3600,
         snoozePresetAddDelaySec: Double = 48 * 3600,
         safeAppsUser: [SafeApp] = [], safeAppsRemoved: [String] = [],
         snoozePresetsUser: [SnoozePreset] = [], snoozePresetsRemoved: [String] = []) {
        self.pollSeconds = pollSeconds; self.countdownPollSeconds = countdownPollSeconds
        self.countdownSeconds = countdownSeconds; self.agentRefreshSeconds = agentRefreshSeconds
        self.graceSeconds = graceSeconds; self.maxAccuracyMeters = maxAccuracyMeters
        self.scanSeconds = scanSeconds; self.scanWindowSeconds = scanWindowSeconds
        self.scanSlackSeconds = scanSlackSeconds; self.materialChangeDeg = materialChangeDeg
        self.feedFreshSeconds = feedFreshSeconds; self.agentGraceSeconds = agentGraceSeconds
        self.agentKickSeconds = agentKickSeconds; self.nuclearRelockSeconds = nuclearRelockSeconds
        self.heldPersistSeconds = heldPersistSeconds
        self.enforcedUser = enforcedUser; self.wifiKeepOn = wifiKeepOn; self.wifiDevice = wifiDevice
        self.snoozeHHMM = snoozeHHMM
        self.policyDelaySec = policyDelaySec; self.zonesDelaySec = zonesDelaySec
        self.gatePolicyDelaySec = gatePolicyDelaySec; self.safeAppsDelaySec = safeAppsDelaySec
        self.snoozePresetAddDelaySec = snoozePresetAddDelaySec
        self.safeAppsUser = safeAppsUser; self.safeAppsRemoved = safeAppsRemoved
        self.snoozePresetsUser = snoozePresetsUser; self.snoozePresetsRemoved = snoozePresetsRemoved
    }

    init(from decoder: Decoder) throws {
        let d = Settings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func dbl(_ k: CodingKeys, _ fb: Double) -> Double { (try? c.decode(Double.self, forKey: k)) ?? fb }
        pollSeconds          = dbl(.pollSeconds, d.pollSeconds)
        countdownPollSeconds = dbl(.countdownPollSeconds, d.countdownPollSeconds)
        countdownSeconds     = dbl(.countdownSeconds, d.countdownSeconds)
        agentRefreshSeconds  = dbl(.agentRefreshSeconds, d.agentRefreshSeconds)
        graceSeconds         = dbl(.graceSeconds, d.graceSeconds)
        maxAccuracyMeters    = dbl(.maxAccuracyMeters, d.maxAccuracyMeters)
        scanSeconds          = dbl(.scanSeconds, d.scanSeconds)
        scanWindowSeconds    = dbl(.scanWindowSeconds, d.scanWindowSeconds)
        scanSlackSeconds     = dbl(.scanSlackSeconds, d.scanSlackSeconds)
        materialChangeDeg    = dbl(.materialChangeDeg, d.materialChangeDeg)
        feedFreshSeconds     = dbl(.feedFreshSeconds, d.feedFreshSeconds)
        agentGraceSeconds    = dbl(.agentGraceSeconds, d.agentGraceSeconds)
        agentKickSeconds     = dbl(.agentKickSeconds, d.agentKickSeconds)
        nuclearRelockSeconds = dbl(.nuclearRelockSeconds, d.nuclearRelockSeconds)
        heldPersistSeconds   = dbl(.heldPersistSeconds, d.heldPersistSeconds)
        enforcedUser         = (try? c.decode(String.self, forKey: .enforcedUser)) ?? d.enforcedUser
        wifiKeepOn           = (try? c.decode(Bool.self,   forKey: .wifiKeepOn)) ?? d.wifiKeepOn
        wifiDevice           = (try? c.decode(String.self, forKey: .wifiDevice)) ?? d.wifiDevice
        snoozeHHMM           = (try? c.decode(String.self, forKey: .snoozeHHMM)) ?? d.snoozeHHMM
        policyDelaySec       = dbl(.policyDelaySec, d.policyDelaySec)
        zonesDelaySec        = dbl(.zonesDelaySec, d.zonesDelaySec)
        gatePolicyDelaySec   = dbl(.gatePolicyDelaySec, d.gatePolicyDelaySec)
        safeAppsDelaySec     = dbl(.safeAppsDelaySec, d.safeAppsDelaySec)
        snoozePresetAddDelaySec = dbl(.snoozePresetAddDelaySec, d.snoozePresetAddDelaySec)
        safeAppsUser    = (try? c.decode([SafeApp].self, forKey: .safeAppsUser)) ?? []
        safeAppsRemoved = (try? c.decode([String].self, forKey: .safeAppsRemoved)) ?? []
        snoozePresetsUser    = (try? c.decode([SnoozePreset].self, forKey: .snoozePresetsUser)) ?? []
        snoozePresetsRemoved = (try? c.decode([String].self, forKey: .snoozePresetsRemoved)) ?? []
    }

    /// Result of loading settings.json — distinguishes ABSENT (fresh install → defaults are fine) from
    /// CORRUPT (present but unparseable → the enforcer must NOT fall to empty defaults, which would set
    /// enforcedUser="" → standby → silently stop enforcing; keep last-known instead). [review L1]
    enum LoadResult { case parsed(Settings), absent, corrupt }

    static func loadResult() -> LoadResult {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.settingsFile)) else { return .absent }
        guard let s = try? JSONDecoder().decode(Settings.self, from: data) else { return .corrupt }
        return .parsed(s)
    }

    /// Lenient load for non-enforcing callers (CLI/agent display): defaults on absent OR corrupt (a
    /// stale display never stops enforcement, so fail-open here is harmless). The enforcer uses
    /// loadResult() so a corrupt file can't disable it.
    static func load() -> Settings {
        if case .parsed(let s) = loadResult() { return s }
        return Settings()
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
