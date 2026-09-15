import Foundation
import MacUtilsCore

/// Single source of truth for on-disk paths, the launchd label, and identifiers.
enum Paths {
    // Root-only config dir (0700). Credentials + tunables + pf ruleset live here.
    static let etcDir      = "/usr/local/etc/nextdns-sidecar"
    static let credFile    = etcDir + "/credentials"          // 0600 root: API_KEY= + PROFILE=
    static let configFile  = etcDir + "/config.json"          // 0644 root: {enforcedUser, delaySec}
    static let pfConf      = etcDir + "/nextdns-lockdown.conf"
    static let localDNSFile = etcDir + "/local-dns.txt"

    // Root-owned runtime state (0755, traversable). The inbox subdir is USER-owned.
    static let supportDir  = "/Library/Application Support/NextDNSSidecar"
    static let armedFile   = supportDir + "/armed"
    static let pendingFile = supportDir + "/delayed-adds.json"   // 0644 root: domain-keyed pending allows
    static let pfStateFile = supportDir + "/pf-state.json"       // 0644 root: pf snapshot for the no-sudo `status`
    static let inboxDir    = supportDir + "/inbox"               // USER-owned: markers dropped here (no sudo)
    static let mArm        = inboxDir + "/arm"                   // flag: request enforcement ON
    static let mBlock      = inboxDir + "/block"                 // contents = domains to block (immediate)
    static let mDelayAdd   = inboxDir + "/delay-add"             // contents = domains to allow after the delay
    static let mAbort      = inboxDir + "/abort"                 // contents = domain(s) or "--all"

    static let label        = "com.minh.nextdns-sidecar.enforcerd"
    static let profilePlist = "/Library/Managed Preferences/com.apple.dnsSettings.managed.plist"
}

/// BAKED delay bounds — compiled in, never read from a file, so a config edit can't push the no-sudo
/// commitment delay below its floor. `set-delay` changes the VALUE but every use clamps into this range.
enum Bounds {
    static let addDelay = 8.0 * 3600 ... 168.0 * 3600   // delay-add: floor 8h, default 12h, ceiling 168h
    static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { Swift.min(Swift.max(v, r.lowerBound), r.upperBound) }
}

/// Root-owned tunables. enforcedUser pins which uid may drop inbox markers (MarkerIO owner-check);
/// delaySec is the delay-add landing delay, clamped by Bounds at every use. Decoded leniently.
struct Config: Codable {
    var enforcedUser: String
    var delaySec: Double

    init(enforcedUser: String = "", delaySec: Double = 12 * 3600) {
        self.enforcedUser = enforcedUser; self.delaySec = delaySec
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enforcedUser = c.lenient(.enforcedUser, default: "")
        delaySec     = c.lenient(.delaySec, default: 12 * 3600)
    }

    static func load() -> Config { loadJSON(Paths.configFile) ?? Config() }
    struct SaveError: Error {}
    func save() throws {
        guard saveJSON(self, to: Paths.configFile, pretty: true) else { throw SaveError() }
    }
    var clampedDelay: Double { Bounds.clamp(delaySec, Bounds.addDelay) }

    /// enforcedUser (name or numeric uid) → uid. nil if unset/unknown.
    func enforcedUID() -> uid_t? { resolveUID(enforcedUser) }
}

/// Ported verbatim from nextdns_discipline.c valid_domain(): ASCII alnum + . - _, no leading/trailing
/// dot/dash, 1..253 chars. Charset-validated before any domain reaches a URL/JSON body (no injection).
func validDomain(_ d: String) -> Bool {
    let chars = Array(d)
    guard (1...253).contains(chars.count) else { return false }
    if chars.first == "." || chars.first == "-" || chars.last == "-" || chars.last == "." { return false }
    for c in chars where !(c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "-" || c == "_")) { return false }
    return true
}

/// Ported from valid_profile(): 1..63 ASCII alphanumerics.
func validProfile(_ p: String) -> Bool {
    let chars = Array(p)
    guard (1...63).contains(chars.count) else { return false }
    return chars.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
}

/// Split a marker's bytes into candidate domains (whitespace/newline separated, empties dropped).
func parseDomains(_ data: Data) -> [String] {
    (String(data: data, encoding: .utf8) ?? "")
        .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        .map(String.init)
}

func isArmedFlag() -> Bool { FileManager.default.fileExists(atPath: Paths.armedFile) }

/// Timestamped daemon log line → stderr (launchd redirects it to the log file; see the LaunchDaemon plist).
func logLine(_ s: String) { logStderr(s) }

/// Drop a marker into the user-owned inbox (no sudo). One escaped line per newline-separated token;
/// empty payload ⇒ a literal "--all" line (abort-all / flag), never a truncate, so an abort-all and a
/// keyed abort inside one tick survive in either order. All inbox writes go through MarkerIO — same
/// contract as demonlock.
func dropMarker(_ path: String, _ payload: String = "") {
    let lines = payload.split(separator: "\n").map(String.init)
    let ok = lines.isEmpty ? MarkerIO.append(path, line: "--all") : MarkerIO.append(path, lines: lines)
    if !ok { fail("error: couldn't write marker \(path) — is the inbox present? Reinstall nextdns-sidecar.") }
}

