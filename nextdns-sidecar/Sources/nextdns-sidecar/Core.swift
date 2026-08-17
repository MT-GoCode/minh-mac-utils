import Foundation

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
        enforcedUser = (try? c.decode(String.self, forKey: .enforcedUser)) ?? ""
        delaySec     = (try? c.decode(Double.self, forKey: .delaySec)) ?? 12 * 3600
    }

    static func load() -> Config {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: Paths.configFile)),
              let c = try? JSONDecoder().decode(Config.self, from: d) else { return Config() }
        return c
    }
    func save() throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: URL(fileURLWithPath: Paths.configFile), options: .atomic)
    }
    var clampedDelay: Double { Bounds.clamp(delaySec, Bounds.addDelay) }

    /// enforcedUser (name or numeric uid) → uid. nil if unset/unknown.
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

/// Sum of d/h/m/s tokens ("12h" → 43200, "1h30m" → 5400). nil on junk. (Trimmed TimeSpec.parseDuration.)
func parseDuration(_ raw: String) -> Double? {
    let s = raw.lowercased().filter { !$0.isWhitespace }
    guard !s.isEmpty else { return nil }
    var total = 0.0, num = "", sawUnit = false
    for ch in s {
        if ch.isNumber { num.append(ch); continue }
        guard let n = Double(num) else { return nil }
        switch ch {
        case "d": total += n * 86400
        case "h": total += n * 3600
        case "m": total += n * 60
        case "s": total += n
        default: return nil
        }
        num = ""; sawUnit = true
    }
    guard num.isEmpty, sawUnit else { return nil }
    return total
}

/// Split a marker's bytes into candidate domains (whitespace/newline separated, empties dropped).
func parseDomains(_ data: Data) -> [String] {
    (String(data: data, encoding: .utf8) ?? "")
        .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        .map(String.init)
}

func nowEpoch() -> Double { Date().timeIntervalSince1970 }

func isArmedFlag() -> Bool { FileManager.default.fileExists(atPath: Paths.armedFile) }

/// Timestamped daemon log line → stderr (launchd redirects it to the log file; see the LaunchDaemon plist).
func logLine(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    FileHandle.standardError.write(Data("\(f.string(from: Date())) \(s)\n".utf8))
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

/// Drop a marker into the user-owned inbox (no sudo). ponytail: single-file marker, so two invocations
/// of the same verb inside one ~5s daemon tick clobber (last wins) — upgrade to unique-named markers if
/// that ever bites. Matches demonlock's dropDelayMarker.
func dropMarker(_ path: String, _ payload: String = "") {
    do { try Data(payload.utf8).write(to: URL(fileURLWithPath: path)) }
    catch { fail("error: couldn't write marker \(path) — is the inbox present? Reinstall nextdns-sidecar.\n  \(error)") }
}

/// Small process helpers. `run` discards output; `capture` returns stdout (stderr discarded).
enum Proc {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
    static func capture(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
