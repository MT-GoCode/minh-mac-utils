import Foundation

/// One whitelisted app: a unique `name` handle, its bundle id + team id, and whether it must be
/// ROOT-OWNED to be spared. rootOwned=true (default) → spared only via Regime A (root-owned bundle +
/// intact signature, any signer). rootOwned=false (`--no-root-ownership`, e.g. Raycast) → spared via
/// Regime B (Developer-ID: anchor apple generic + bid + team OU), which is REFUSED for our own team
/// (we hold that key). See Sensors.spareVerified.
struct SafeApp: Codable, Equatable {
    var name: String
    var bid: String
    var tid: String
    var rootOwned: Bool
}

/// The effective spare list = compiled defaults + user additions − user removals, with com.demonlock
/// forced present (removing it kills the agent on lockout → nuclear WindowServer loop). Plus the CLI
/// (`safe-apps …`) and the daemon-side registry tick that applies delayed registrations.
enum SafeApps {
    static let ownTeam = Sensors.ownTeamID

    /// Compiled defaults. Own apps (root-owned installs) are rootOwned=true; third-party menubar
    /// utilities are rootOwned=false (Developer-ID Regime B). com.demonlock is UNREMOVABLE.
    static let defaults: [SafeApp] = [
        SafeApp(name: "demonlock",              bid: "com.demonlock",                     tid: ownTeam,       rootOwned: true),
        SafeApp(name: "wtalk",                  bid: "com.wtalk.daemon",                  tid: ownTeam,       rootOwned: true),
        SafeApp(name: "remote-agent-connector", bid: "com.minh.remote-agent-connector",   tid: ownTeam,       rootOwned: true),
        SafeApp(name: "msv2",                   bid: "com.minh.msv2",                     tid: ownTeam,       rootOwned: true),
        SafeApp(name: "stayup",                 bid: "com.minh.stayup",                   tid: ownTeam,       rootOwned: true),
        SafeApp(name: "paseo-daemon",           bid: "sh.paseo.desktop.helper",           tid: "99ZMJMKU9Y", rootOwned: false),
        SafeApp(name: "alttab",                 bid: "com.lwouis.alt-tab-macos",          tid: "QXD7GW8FHY", rootOwned: false),
        SafeApp(name: "raycast",                bid: "com.raycast.macos",                 tid: "SY64MV22J9", rootOwned: false),
        SafeApp(name: "shottr",                 bid: "cc.ffitch.shottr",                  tid: "2Y683PRQWN", rootOwned: false),
        SafeApp(name: "amphetamine",            bid: "com.if.Amphetamine",                tid: "U5SR49N3PT", rootOwned: false),
        SafeApp(name: "betterdisplay",          bid: "pro.betterdisplay.BetterDisplay",   tid: "299YSU96J7", rootOwned: false),
        SafeApp(name: "scroll-reverser",        bid: "com.pilotmoon.scroll-reverser",     tid: "6W6K75YWQ9", rootOwned: false),
        SafeApp(name: "karabiner-core",         bid: "org.pqrs.Karabiner-Core-Service",   tid: "G43BCU2T37", rootOwned: false),
        SafeApp(name: "karabiner-menu",         bid: "org.pqrs.Karabiner-Menu",           tid: "G43BCU2T37", rootOwned: false),
        SafeApp(name: "karabiner-notify",       bid: "org.pqrs.Karabiner-NotificationWindow", tid: "G43BCU2T37", rootOwned: false),
    ]

    /// Never removable — losing this spare is self-defeating.
    static let unremovableBIDs: Set<String> = ["com.demonlock"]

    /// Baked, unremovable blocklist: bundle ids `register` refuses. Browsers (every variant) + the Paseo
    /// desktop UI — sparing any of them would defeat the whole point of a lockout. [Minh]
    static let blocklistBIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Beta",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.operasoftware.Opera", "com.operasoftware.OperaGX",
        "com.vivaldi.Vivaldi", "ru.yandex.desktop.yandex-browser",
        "sh.paseo.desktop",
    ]

    // MARK: - effective list

    /// defaults + user adds (by bid, user wins) − user removes, com.demonlock forced present.
    static func effective(_ settings: Settings = Settings.load()) -> [SafeApp] {
        var byBID: [String: SafeApp] = [:]
        for a in defaults { byBID[a.bid] = a }
        for a in settings.safeAppsUser { byBID[a.bid] = a }
        for bid in settings.safeAppsRemoved where !unremovableBIDs.contains(bid) { byBID.removeValue(forKey: bid) }
        if byBID["com.demonlock"] == nil, let d = defaults.first(where: { $0.bid == "com.demonlock" }) { byBID[d.bid] = d }
        return byBID.values.sorted { $0.name < $1.name }
    }

    static func effectiveMap(_ settings: Settings = Settings.load()) -> [String: SafeApp] {
        Dictionary(effective(settings).map { ($0.bid, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - pending registry (root-owned; drives delayed registrations + `show`)

    struct Pending: Codable { var app: SafeApp; var requestedAt: Double; var applyAt: Double }
    struct Registry: Codable {
        var pending: [String: Pending] = [:]   // name → pending add
        static func load() -> Registry {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: Paths.safeAppsPendingFile)),
                  let r = try? JSONDecoder().decode(Registry.self, from: d) else { return Registry() }
            return r
        }
        func save() {
            let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
            if let d = try? e.encode(self) { try? d.write(to: URL(fileURLWithPath: Paths.safeAppsPendingFile), options: .atomic) }
        }
    }

    /// Published status for `show` (the pending adds + their landing times).
    struct Status: Codable { var pending: [PendingView] = [] }
    struct PendingView: Codable { var name: String; var bid: String; var applyAtEpoch: Double }

    // MARK: - validation (shared by CLI register + daemon apply)

    /// nil if OK, else the reason to reject. Names: [a-z0-9-]{1,24}, unique vs defaults/effective.
    static func rejectReason(_ app: SafeApp, settings: Settings) -> String? {
        let n = app.name
        guard (1...24).contains(n.count), n.allSatisfy({ $0.isLowercase && $0.isLetter || $0.isNumber || $0 == "-" }) else {
            return "name must be 1–24 chars of [a-z0-9-]"
        }
        guard !app.bid.isEmpty, app.bid.count <= 255, app.bid.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else {
            return "bundle id looks invalid"
        }
        if blocklistBIDs.contains(app.bid) { return "\(app.bid) is on the baked blocklist (browsers / paseo desktop) — never spareable" }
        if !app.rootOwned && app.tid == ownTeam { return "own-team apps can't use --no-root-ownership (we hold that key) — they must be root-owned" }
        guard app.tid.count == 10, app.tid.allSatisfy({ $0.isUppercase && $0.isLetter || $0.isNumber }) else {
            return "team id must be a 10-char Apple Team ID (e.g. SY64MV22J9)"
        }
        // A name that collides with a DIFFERENT bid is rejected (names are unique handles).
        for a in effective(settings) where a.name == n && a.bid != app.bid { return "the name '\(n)' is already used by \(a.bid)" }
        return nil
    }

    // MARK: - daemon tick (applies delayed registrations; immediate removes; aborts)

    /// One tick: consume the immediate `remove` marker, the `abort` marker, and the delayed `register`
    /// marker; apply any pending registration whose time has come. All markers owner-checked via MarkerIO.
    /// Returns the status to publish. Writes settings.json (root) when a registration lands or a remove is
    /// applied. Delay is Bounds-clamped.
    @discardableResult
    static func tick(now: Double, enforcedUID: uid_t?, delaySec: Double) -> Status {
        var reg = Registry.load()

        if let euid = enforcedUID {
            // remove (immediate, tightening): drop the app from the user set / tombstone a default.
            if let data = MarkerIO.consume(Paths.saRemoveMarker, enforcedUID: euid) {
                let name = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                applyRemove(name: name)
                reg.pending.removeValue(forKey: name); reg.save()
            }
            // abort a pending delayed registration.
            if let data = MarkerIO.consume(Paths.saAbortMarker, enforcedUID: euid) {
                let arg = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if arg == "--all" { reg.pending.removeAll() } else { reg.pending.removeValue(forKey: arg) }
                reg.save()
            }
            // register (delayed): validate + (re)queue by name.
            if let data = MarkerIO.consume(Paths.saRegisterMarker, enforcedUID: euid),
               let app = try? JSONDecoder().decode(SafeApp.self, from: data),
               rejectReason(app, settings: Settings.load()) == nil {
                reg.pending[app.name] = Pending(app: app, requestedAt: now, applyAt: now + delaySec)
                reg.save()
            }
        }

        // Apply any pending registration that's due.
        var applied = false
        for (name, p) in reg.pending where now >= p.applyAt {
            if rejectReason(p.app, settings: Settings.load()) == nil { applyAdd(p.app); applied = true }
            reg.pending.removeValue(forKey: name)
        }
        if applied { reg.save() }

        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"
        return Status(pending: reg.pending.values
            .sorted { $0.app.name < $1.app.name }
            .map { PendingView(name: $0.app.name, bid: $0.app.bid, applyAtEpoch: $0.applyAt) })
    }

    /// Add/replace a user entry in settings.json (root-writable). Also un-tombstones the bid.
    static func applyAdd(_ app: SafeApp) {
        var s = Settings.load()
        s.safeAppsUser.removeAll { $0.bid == app.bid }
        s.safeAppsUser.append(app)
        s.safeAppsRemoved.removeAll { $0 == app.bid }
        try? s.save()
    }

    /// Remove by NAME: drop a user entry, or tombstone a compiled default (never com.demonlock).
    static func applyRemove(name: String) {
        var s = Settings.load()
        if let u = s.safeAppsUser.first(where: { $0.name == name }) {
            s.safeAppsUser.removeAll { $0.name == name }
            s.safeAppsRemoved.removeAll { $0 == u.bid }   // a user add just disappears; no tombstone needed
        } else if let d = defaults.first(where: { $0.name == name }), !unremovableBIDs.contains(d.bid) {
            if !s.safeAppsRemoved.contains(d.bid) { s.safeAppsRemoved.append(d.bid) }
        }
        try? s.save()
    }
}
