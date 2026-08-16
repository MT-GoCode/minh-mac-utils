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
    static let ownTeam = SensorFeeder.ownTeamID

    /// Compiled default = demonlock ITSELF only. It must spare its own bundle (removing it kills the
    /// agent on lockout → nuclear WindowServer loop), so that one stays baked and unremovable. EVERY
    /// other spare — your own apps AND third-party utils — is registered dynamically at install time
    /// (each installer runs `demonlock safe-apps register …`; the no-installer third-party set via
    /// demonlock/register-recommended-spares.sh). So demonlock carries no knowledge of other apps.
    static let defaults: [SafeApp] = [
        SafeApp(name: "demonlock", bid: "com.demonlock", tid: ownTeam, rootOwned: true),
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
        static func load() -> Registry { loadJSON(Paths.safeAppsPendingFile) ?? Registry() }
        func save() { saveJSON(self, to: Paths.safeAppsPendingFile) }
    }

    /// Published status for `show` (the pending adds + their landing times).
    struct Status: Codable { var pending: [PendingView] = [] }
    struct PendingView: Codable { var name: String; var bid: String; var applyAtEpoch: Double }

    /// A [a-z0-9-]{1,24} handle derived from a bundle id (its last dotted component), for the
    /// remove/show/abort handle. Overridable with --name; only needs to be unique, not meaningful.
    static func deriveName(_ bid: String) -> String {
        let last = String(bid.split(separator: ".").last ?? Substring(bid))
        var out = ""
        for c in last.lowercased() where out.count < 24 {
            if c.isASCII, c.isLetter || c.isNumber || c == "-" { out.append(c) }
        }
        return out.isEmpty ? "app" : out
    }

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
        // Regime A (root-owned) never reads the team, so tid is unused there and may be empty — nothing
        // to validate. Only Regime B (--no-root-ownership) verifies a real Team ID, and refuses our own.
        if !app.rootOwned {
            if app.tid == ownTeam { return "own-team apps can't use --no-root-ownership (we hold that key) — they must be root-owned" }
            guard app.tid.count == 10, app.tid.allSatisfy({ $0.isUppercase && $0.isLetter || $0.isNumber }) else {
                return "team id must be a 10-char Apple Team ID (e.g. SY64MV22J9)"
            }
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

        // Apply any pending registration that's due. Save on ANY removal (applied OR rejected-at-landing),
        // so a due-but-invalid entry is dropped rather than re-firing every tick forever (matches siblings).
        var changed = false
        for (name, p) in reg.pending where now >= p.applyAt {
            if rejectReason(p.app, settings: Settings.load()) == nil { applyAdd(p.app) }
            reg.pending.removeValue(forKey: name); changed = true
        }
        if changed { reg.save() }

        return Status(pending: reg.pending.values
            .sorted { $0.app.name < $1.app.name }
            .map { PendingView(name: $0.app.name, bid: $0.app.bid, applyAtEpoch: $0.applyAt) })
    }

    /// Add/replace a user entry in settings.json (root-writable). Also un-tombstones the bid.
    static func applyAdd(_ app: SafeApp) {
        Settings.mutate { s in
            s.safeAppsUser.removeAll { $0.bid == app.bid }
            s.safeAppsUser.append(app)
            s.safeAppsRemoved.removeAll { $0 == app.bid }
        }
    }

    /// Drop any queued delayed registration for this bid — so an IMMEDIATE register isn't silently
    /// reverted when a stale delayed entry for the same app lands later. Immediate CLI path only (the
    /// tick removes entries as it applies them, so it must not double-touch the registry here).
    static func clearPending(bid: String) {
        var reg = Registry.load()
        let before = reg.pending.count
        reg.pending = reg.pending.filter { $0.value.app.bid != bid }
        if reg.pending.count != before { reg.save() }
    }

    /// Remove by NAME: drop a user entry, or tombstone a compiled default (never com.demonlock).
    static func applyRemove(name: String) {
        Settings.mutate { s in
            if let u = s.safeAppsUser.first(where: { $0.name == name }) {
                s.safeAppsUser.removeAll { $0.name == name }
                s.safeAppsRemoved.removeAll { $0 == u.bid }   // a user add just disappears; no tombstone needed
            } else if let d = defaults.first(where: { $0.name == name }), !unremovableBIDs.contains(d.bid) {
                if !s.safeAppsRemoved.contains(d.bid) { s.safeAppsRemoved.append(d.bid) }
            }
        }
    }
}
