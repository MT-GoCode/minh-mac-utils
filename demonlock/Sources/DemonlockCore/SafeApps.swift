import Foundation
import MacUtilsCore

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

/// The effective spare list = compiled defaults + user additions − user removals, with com.minh.demonlock
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
        SafeApp(name: "demonlock", bid: "com.minh.demonlock", tid: ownTeam, rootOwned: true),
    ]

    /// Never removable — losing this spare is self-defeating.
    static let unremovableBIDs: Set<String> = ["com.minh.demonlock"]

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

    /// defaults + user adds (by bid, user wins) − user removes, com.minh.demonlock forced present.
    static func effective(_ settings: Settings = Settings.load()) -> [SafeApp] {
        var byBID: [String: SafeApp] = [:]
        for a in defaults { byBID[a.bid] = a }
        for a in settings.safeAppsUser { byBID[a.bid] = a }
        for bid in settings.safeAppsRemoved where !unremovableBIDs.contains(bid) { byBID.removeValue(forKey: bid) }
        if byBID["com.minh.demonlock"] == nil, let d = defaults.first(where: { $0.bid == "com.minh.demonlock" }) { byBID[d.bid] = d }
        return byBID.values.sorted { $0.name < $1.name }
    }

    static func effectiveMap(_ settings: Settings = Settings.load()) -> [String: SafeApp] {
        Dictionary(effective(settings).map { ($0.bid, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - pending registry (root-owned; drives delayed registrations + `show`)

    /// The pending-registration DelayQueue (payload = canonical SafeApp JSON, key = name — so a
    /// re-register with a DIFFERENT bid/tid/rootOwned replaces + resets, the user's flag case).
    static func queue() -> DelayQueue {
        DelayQueue(kind: "safe-apps",
                   store: .file(Paths.safeAppsPendingFile, legacyDecode: Legacy.safeApps()),
                   requestMarker: Paths.saRegisterMarker, abortMarker: Paths.saAbortMarker,
                   onFailure: .drop, payloadIsJSON: true, auditLog: Paths.queueAuditLog)
    }

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

    // MARK: - daemon tick (calls consumeMarkers then applyDue on its own queue)

    /// One tick: immediate `remove` marker (the CLI also writes the abort marker for the same name,
    /// so a pending delayed-add of a removed app dies via the queue's own abort path), then the
    /// register queue. Validation (blocklist, team rules, name collisions) runs at queue AND landing.
    @discardableResult
    static func tick(now: Double, enforcedUID: uid_t?, delaySec: Double) -> DelayQueue.QStatus {
        let q = queue()
        if let euid = enforcedUID, let names = MarkerIO.consumeLines(Paths.saRemoveMarker, enforcedUID: euid) {
            for name in Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !name.isEmpty {
                applyRemove(name: name)
                q.rootCancel(keys: [name], now: now, reason: "removed")   // remove kills a same-name pending row
            }
        }
        let decode: (String) -> SafeApp? = { try? JSONDecoder().decode(SafeApp.self, from: Data($0.utf8)) }
        let validate: (String) -> Bool = { line in decode(line).map { rejectReason($0, settings: Settings.load()) == nil } ?? false }
        q.consumeMarkers(now: now, enforcedUID: enforcedUID,
                         delaySec: { _ in delaySec },
                         key: { decode($0)?.name },
                         validate: validate)
        return q.applyDue(now: now, validate: validate) { due in
            Dictionary(uniqueKeysWithValues: due.map { d in
                guard let app = decode(d.payload) else { return (d.key, (false, String?.some("undecodable"))) }
                applyAdd(app)
                return (d.key, (true, nil))
            })
        }
    }

    /// Add/replace a user entry in settings.json (root-writable). Also un-tombstones the bid.
    static func applyAdd(_ app: SafeApp) {
        Settings.mutate { s in
            s.safeAppsUser.removeAll { $0.bid == app.bid }
            s.safeAppsUser.append(app)
            s.safeAppsRemoved.removeAll { $0 == app.bid }
        }
    }

    /// ROOT-only (immediate `register` CLI path): drop any queued delayed registration for this bid
    /// so an IMMEDIATE register isn't silently reverted when a stale delayed entry lands later.
    /// Root edits the root-owned queue state directly (it cannot route through the user-owned inbox).
    static func clearPending(bid: String) {
        let q = queue()
        let victims = q.store.load().pending
            .filter { (try? JSONDecoder().decode(SafeApp.self, from: Data($0.value.payload.utf8)))?.bid == bid }
            .map(\.key)
        q.rootCancel(keys: Array(victims), now: nowEpoch(), reason: "superseded by immediate register")
    }

    /// Remove by NAME: drop a user entry, or tombstone a compiled default (never com.minh.demonlock).
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
