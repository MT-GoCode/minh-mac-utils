import Foundation

/// The pf "bypass wall" — ported from nextdns-lockdownd. Asserts our ruleset while armed, keeps the
/// captive-portal door (<local_dns>) tracking the current network, and fails closed (flushes the door)
/// if the Encrypted-DNS profile is removed. Standalone: shells out to pfctl/route/scutil.
enum Lockdown {
    static let marker = "nextdns-lockdown-dns53"        // signature label identifying our ruleset
    static let pfctl  = "/sbin/pfctl"
    static let route  = "/sbin/route"
    static let scutil = "/usr/sbin/scutil"

    /// /dev/pf is root-only. As a normal user pfctl fails, `Proc.capture` discards stderr, and the
    /// resulting EMPTY stdout reads as "not enabled" — so these two are meaningless unless `isRoot`.
    /// `printStatus` used to call them ungated and therefore reported a healthy armed system as
    /// "pf: disabled / not loaded" on every no-sudo run. Gate every DISPLAY use on `isRoot`; the
    /// daemon (always root) may call them directly.
    static var isRoot: Bool { geteuid() == 0 }
    static func pfEnabled()      -> Bool { Proc.capture(pfctl, ["-s", "info"]).contains("Status: Enabled") }
    static func pfOursLoaded()   -> Bool { Proc.capture(pfctl, ["-sr"]).contains(marker) }

    /// A published snapshot older than this is reported as `unknown`, not as its last value — a stopped
    /// enforcerd must never look like a healthy one. Sized well above one tick, NOT 6*interval: a tick
    /// that consumes a bulk `domains block` marker runs one synchronous API call per domain and can
    /// last minutes, and a healthy-but-busy daemon reading as dead is the same false alarm this gauge
    /// exists to kill. The daemon also publishes at the TOP of each tick, so the worst case is one
    /// marker phase, not one full tick.
    static let stateStaleAfter = 120.0
    static func profilePresent() -> Bool { FileManager.default.fileExists(atPath: Paths.profilePlist) }
    /// The no-browser-doh profile installed? It forces Secure-DNS OFF for all common browsers in one
    /// profile; Chrome's managed pref (always a payload, world-readable) is the non-root signal it's on.
    static func browserProfilePresent() -> Bool {
        Proc.capture("/usr/bin/defaults", ["read", "/Library/Managed Preferences/com.google.Chrome", "DnsOverHttpsMode"])
            .trimmingCharacters(in: .whitespacesAndNewlines) == "off"
    }

    // ---- pf ruleset assert / restore ----

    /// Ensure pf is enabled and OUR ruleset is loaded; re-assert if tampered. Validate before loading.
    static func assertPF() {
        if pfEnabled() && pfOursLoaded() { return }
        if Proc.run(pfctl, ["-n", "-f", Paths.pfConf]) != 0 {
            logLine("ERROR: ruleset failed validation; refusing to load"); return
        }
        Proc.run(pfctl, ["-f", Paths.pfConf])
        Proc.run(pfctl, ["-e"])                          // harmless 'already enabled' if it was
        if pfEnabled() && pfOursLoaded() { logLine("re-asserted pf ruleset (was tampered or not loaded)") }
        else { logLine("WARNING: pf re-assert attempted but state still off") }
    }

    /// While disarmed: remove our ruleset once and idle.
    static func restorePF() {
        if pfOursLoaded() {
            Proc.run(pfctl, ["-f", "/etc/pf.conf"])
            Proc.run(pfctl, ["-d"])
            logLine("DISARMED: restored default pf ruleset and disabled pf")
        }
    }

    // ---- published pf state (lets the no-sudo `status` tell "off" apart from "couldn't look") ----

    /// What the ROOT daemon last observed. Written world-readable every tick so `status`, a no-sudo
    /// verb, reports something it actually saw rather than the artifact of a pfctl call it was never
    /// permitted to make.
    struct PFState: Codable {
        var enabled: Bool
        var oursLoaded: Bool
        var armed: Bool
        var at: Double                                    // epoch seconds, stamped by the daemon
        var age: Double { max(0, nowEpoch() - at) }        // computed ⇒ not encoded
    }

    /// Root-only; a no-op anywhere else. Called on EVERY tick (not just on change) so that snapshot
    /// age doubles as a liveness signal for the daemon itself.
    static func publishState(armed: Bool) {
        guard isRoot else { return }
        let s = PFState(enabled: pfEnabled(), oursLoaded: pfOursLoaded(), armed: armed, at: nowEpoch())
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        guard let d = try? e.encode(s) else { return }
        try? d.write(to: URL(fileURLWithPath: Paths.pfStateFile), options: .atomic)
        // .atomic writes a temp file then renames, so the mode has to be re-asserted: if this ends up
        // root-only, status silently falls back to "unknown" and we're halfway back to the old bug.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Paths.pfStateFile)
    }

    static func readState() -> PFState? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: Paths.pfStateFile)),
              let s = try? JSONDecoder().decode(PFState.self, from: d) else { return nil }
        return s
    }

    // ---- captive-portal door ----

    static func staticRanges() -> [String] {
        guard let text = try? String(contentsOfFile: Paths.localDNSFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Hosts THIS network handed us: default gateway (v4+v6) + DHCP resolvers. Strip IPv6 zone ids
    /// (%en0 — invalid in a pf table); drop loopback/wildcard. Same trust as a manual `dig @gateway`.
    static func learnHosts() -> [String] {
        func gateway(_ args: [String]) -> String? {
            for line in Proc.capture(route, args).split(separator: "\n") {
                let t = String(line).trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("gateway:") { return String(t.dropFirst("gateway:".count)).trimmingCharacters(in: .whitespaces) }
            }
            return nil
        }
        var raw: [String] = []
        if let g = gateway(["-n", "get", "default"]) { raw.append(g) }
        if let g = gateway(["-n", "get", "-inet6", "default"]) { raw.append(g) }
        for line in Proc.capture(scutil, ["--dns"]).split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if let i = parts.firstIndex(where: { $0.hasPrefix("nameserver[") }), parts.count > i + 2 {
                raw.append(parts[i + 2])
            }
        }
        var seen = Set<String>(); var out: [String] = []
        for h0 in raw {
            var h = h0
            if let r = h.range(of: "%") { h = String(h[..<r.lowerBound]) }
            if h.isEmpty || h.hasPrefix("127.") || h == "0.0.0.0" || h == "::1" || h == "0:0:0:0:0:0:0:1" { continue }
            if seen.insert(h).inserted { out.append(h) }
        }
        return out.sorted()
    }

    /// Atomic membership swap of <local_dns>: static private ranges + this network's learned hosts.
    static func syncCaptiveDoor() {
        let desired = Array(Set(staticRanges() + learnHosts())).filter { !$0.isEmpty }.sorted()
        guard !desired.isEmpty else { return }
        if Proc.run(pfctl, ["-t", "local_dns", "-T", "replace"] + desired) != 0 {
            logLine("WARNING: <local_dns> replace failed — captive door may be stale")
        }
    }

    /// Profile present → keep the door synced. MISSING → FLUSH the door (fail-closed: no fallback to the
    /// gateway's unfiltered resolver). Returns the new profile-state string (caller logs transitions only).
    /// ponytail: dropped the original best-effort profile REINSTALL — the installer no longer caches a
    /// mobileconfig, and the fail-closed flush IS the security guarantee. Re-add a cache if wanted.
    static func assertProfile(prev: String) -> String {
        if profilePresent() {
            syncCaptiveDoor()
            if prev != "present" { logLine("Encrypted-DNS profile: present") }
            return "present"
        } else {
            Proc.run(pfctl, ["-t", "local_dns", "-T", "flush"])
            if prev != "absent" { logLine("ALERT: Encrypted-DNS profile MISSING — flushed <local_dns> (fail-closed)") }
            return "absent"
        }
    }

    // ---- status (no sudo) ----

    static func printStatus() {
        let red = "\u{1b}[31m", dim = "\u{1b}[2m", rst = "\u{1b}[0m"
        print("== NextDNS Sidecar :: network lockdown ==")
        print("  state:        " + (isArmedFlag() ? "ARMED (enforcing)" : "disarmed"))
        printPFGauge(red: red, dim: dim, rst: rst)
        if profilePresent() {
            print("  DoH profile:  installed")
            print("  DoH server:   \(profileURL())")
        } else {
            print("  DoH profile:  \(red)MISSING\(rst)  (no encrypted resolver — arm is refused)")
        }
        print("  browser DoH:  " + (browserProfilePresent() ? "locked (no-browser-doh installed)"
                                     : "\(red)OPEN — no-browser-doh NOT installed\(rst)  (arm is refused)"))
        print("  resolution:   " + (resolvesSystem() ? "working" : "NOT resolving"))
        let daemon = !Proc.capture("/bin/launchctl", ["print", "system/\(Paths.label)"]).isEmpty
        print("  daemon:       " + (daemon ? "loaded" : "NOT loaded"))
    }

    /// The pf gauge: three sources in descending authority, with `unknown` as a FIRST-CLASS answer.
    /// Printing "disabled" when we merely failed to look is exactly the bug this replaces — it made a
    /// fully-enforcing system read as off after every reboot, which trained the operator to ignore it.
    private static func printPFGauge(red: String, dim: String, rst: String) {
        func report(_ enabled: Bool, _ loaded: Bool, _ note: String) {
            print("  pf:           " + (enabled ? "enabled" : "disabled") + "\(dim)  \(note)\(rst)")
            print("  pf rules:     " + (loaded ? "loaded" : "not loaded"))
        }
        func unknown(_ why: String) {
            print("  pf:           \(red)unknown\(rst)\(dim)  \(why)\(rst)")
            print("  pf rules:     \(red)unknown\(rst)")
        }
        if isRoot { report(pfEnabled(), pfOursLoaded(), "(live)"); return }
        guard let s = readState() else {
            unknown("(no snapshot — daemon not running, or pre-dates this build)"); return
        }
        if s.age < stateStaleAfter { report(s.enabled, s.oursLoaded, "(daemon snapshot, \(Int(s.age))s ago)") }
        else { unknown("(snapshot \(Int(s.age))s stale — is enforcerd running?)") }
    }

    // ---- resolution + profile URL helpers ----

    /// Resolve through the SYSTEM resolver (mDNSResponder → DoH → NextDNS), not `dig`. Used by status,
    /// selftest, and the arm safety guard.
    static func resolvesSystem(_ host: String = "apple.com") -> Bool {
        Proc.capture("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", host]).contains("ip_address")
    }

    /// The DoH endpoint the installed Encrypted-DNS profile points at (plutil-extracted).
    static func profileURL() -> String {
        let u = Proc.capture("/usr/bin/plutil", ["-extract", "DNSSettings.ServerURL", "raw", Paths.profilePlist])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return u.isEmpty ? "(unknown)" : u
    }

    /// BLOCKED iff the system resolver returns nothing or only 0.0.0.0 (NextDNS's block reply). IPv4 (A)
    /// only, matching the old nextdns-test; an allowed IPv6-only domain would read BLOCKED (rare).
    static func isBlocked(_ d: String) -> Bool {
        let out = Proc.capture("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", d])
        let real = out.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("ip_address:") else { return nil }
            let ip = String(t.dropFirst("ip_address:".count)).trimmingCharacters(in: .whitespaces)
            return (ip.isEmpty || ip == "0.0.0.0") ? nil : ip
        }
        return real.isEmpty
    }

    /// A real resolved address from `dig +short`, or nil if the lookup produced none.
    ///
    /// `+short` prints only answers on SUCCESS — but on failure dig still writes its banner and
    /// diagnostics to STDOUT (`; <<>> DiG 9.10.6 <<>> ...`, `;; connection timed out; no servers could
    /// be reached`). The old check took `.split("\n").first`, so a correctly BLOCKED resolver handed
    /// back the banner line, which is non-empty, and got reported as `LEAKS -> ; <<>> DiG 9.10.6`.
    /// Every successful block looked like a failure. Only an actual address counts as resolution.
    /// .answered = a real address came back; .blocked = dig ran and got nothing; .broken = dig itself
    /// couldn't run. The third case must NOT read as "blocked" — that's the unearned PASS this whole
    /// pass is about, and `Proc.capture` alone can't tell it apart because it discards exit status.
    enum DigOutcome { case answered(String), blocked, broken(Int32) }

    static func digAnswer(_ server: String, _ host: String = "example.com") -> DigOutcome {
        let (out, rc) = Proc.captureStatus("/usr/bin/dig", ["+time=3", "+tries=1", "@\(server)", host, "+short"])
        if rc == -1 { return .broken(rc) }                       // couldn't exec dig at all
        if let ip = out.split(separator: "\n")
            .map({ String($0).trimmingCharacters(in: .whitespaces) })
            .first(where: isIPLiteral) { return .answered(ip) }
        return .blocked
    }

    /// Strict: dotted-quad or colon-hex only. dig's `;`-prefixed diagnostics and CNAME targets are not
    /// evidence that anything resolved.
    static func isIPLiteral(_ s: String) -> Bool {
        if s.isEmpty || s.hasPrefix(";") { return false }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    // ---- reload (root) + selftest (no sudo) ----

    /// Re-validate + reload the pf ruleset, picking up on-disk table edits without a disarm/arm cycle.
    static func reload() {
        if Proc.run(pfctl, ["-n", "-f", Paths.pfConf]) != 0 { fail("ruleset FAILED validation — not reloaded") }
        Proc.run(pfctl, ["-f", Paths.pfConf]); Proc.run(pfctl, ["-e"])
        print("Ruleset re-validated and reloaded.")
    }

    /// Actively probe the real bypass vectors + per-browser DoH policy, report OPEN/CLOSED vs armed state.
    /// Ported from the old nextdns-lockdown selftest.
    static func selfTest() {
        let grn = "\u{1b}[32m", red = "\u{1b}[31m", dim = "\u{1b}[2m", rst = "\u{1b}[0m"
        func ok(_ s: String)   { print("  \(grn)PASS\(rst) \(s)") }
        func bad(_ s: String)  { print("  \(red)FAIL\(rst) \(s)") }
        func note(_ s: String) { print("  \(dim)\(s)\(rst)") }
        let armed = isArmedFlag()
        print("== NextDNS Sidecar self-test ==")
        note(armed ? "state ARMED  -> bypass vectors should be CLOSED"
                   : "state DISARMED -> bypass vectors will be OPEN (expected when off)")
        print("")

        for server in ["8.8.8.8", "1.1.1.1"] {
            switch digAnswer(server) {
            case .answered(let ans):
                if armed { bad("plain DNS to \(server) LEAKS -> \(ans)") }
                else { note("plain DNS to \(server) open (\(ans))") }
            case .blocked:      ok("plain DNS to \(server) is blocked")
            case .broken(let rc): note("plain DNS to \(server) INCONCLUSIVE — dig failed to run (rc=\(rc))")
            }
        }
        // Empty stdout used to mean "blocked", but curl also prints nothing when the network is simply
        // broken — a PASS you have not earned. Split it: non-zero exit = genuinely couldn't connect;
        // a parsed DNS answer = a real leak; anything else is inconclusive and says so.
        let (dohOut, dohRC) = Proc.captureStatus("/usr/bin/curl",
                  ["-s", "--max-time", "6", "-H", "accept: application/dns-json",
                   "https://1.1.1.1/dns-query?name=example.com&type=A"])
        // rc != 0 alone can't distinguish "pf dropped it" from "the network is down" — both give 28.
        // Gate the PASS on a control probe; without it a broken network scores as protection.
        // And while armed, completing the TLS handshake at all IS the leak: curl returns 0 on HTTP
        // 4xx/5xx too, so judging by body would let a rate-limited but REACHABLE 1.1.1.1 read as safe.
        let netUp = resolvesSystem()
        if dohRC == 0 {
            if armed { bad("DoH to https://1.1.1.1 LEAKS (reachable, rc=0)") }
            else { note("DoH to https://1.1.1.1 open") }
        } else if netUp {
            ok("DoH to https://1.1.1.1 is blocked (curl rc=\(dohRC))")
        } else {
            note("DoH to https://1.1.1.1 INCONCLUSIVE — curl rc=\(dohRC) but system DNS is down too")
        }
        _ = dohOut

        if Proc.run("/usr/bin/nc", ["-z", "-G", "3", "-w", "3", "1.1.1.1", "853"]) == 0 {
            if armed { bad("DoT 853 to 1.1.1.1 reachable") } else { note("DoT 853 to 1.1.1.1 reachable (open)") }
        } else { ok("DoT 853 to 1.1.1.1 is blocked") }

        if profilePresent() { ok("Encrypted-DNS profile installed (\(profileURL()))") }
        else { bad("Encrypted-DNS profile MISSING — install the NextDNS .mobileconfig") }

        let browsers: [(String, String, String)] = [
            ("/Applications/Google Chrome.app", "com.google.Chrome", "Chrome"),
            ("/Applications/Google Chrome Beta.app", "com.google.Chrome.beta", "Chrome Beta"),
            ("/Applications/Google Chrome Dev.app", "com.google.Chrome.dev", "Chrome Dev"),
            ("/Applications/Google Chrome Canary.app", "com.google.Chrome.canary", "Chrome Canary"),
            ("/Applications/Microsoft Edge.app", "com.microsoft.Edge", "Edge"),
            ("/Applications/Microsoft Edge Beta.app", "com.microsoft.Edge.Beta", "Edge Beta"),
            ("/Applications/Microsoft Edge Dev.app", "com.microsoft.Edge.Dev", "Edge Dev"),
            ("/Applications/Microsoft Edge Canary.app", "com.microsoft.Edge.Canary", "Edge Canary"),
            ("/Applications/Brave Browser.app", "com.brave.Browser", "Brave"),
            ("/Applications/Vivaldi.app", "com.vivaldi.Vivaldi", "Vivaldi"),
            ("/Applications/Opera.app", "com.operasoftware.Opera", "Opera"),
            ("/Applications/Arc.app", "company.thebrowser.Browser", "Arc"),
        ]
        let fm = FileManager.default
        for (app, dom, lbl) in browsers where fm.fileExists(atPath: app) {
            let v = Proc.capture("/usr/bin/defaults", ["read", "/Library/Managed Preferences/\(dom)", "DnsOverHttpsMode"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if v == "off" { ok("\(lbl) Secure DNS forced off (policy)") }
            else { bad("\(lbl) installed but Secure-DNS policy NOT set — install/extend no-browser-doh.mobileconfig") }
        }
        if fm.fileExists(atPath: "/Applications/Firefox.app") {
            let v = Proc.capture("/usr/bin/defaults", ["read", "/Library/Managed Preferences/org.mozilla.firefox", "DNSOverHTTPS"])
            if v.contains("Enabled = 0") { ok("Firefox DoH off (locked policy)") }
            else { bad("Firefox installed but DoH policy NOT set — install no-browser-doh.mobileconfig") }
        }

        if resolvesSystem() { ok("normal resolution works (system resolver)") }
        else { bad("system resolution failed — DNS may be down (or mid captive-portal login)") }
        print("")
        note("Verify filtering in a browser: https://test.nextdns.io should show your profile.")
    }
}
