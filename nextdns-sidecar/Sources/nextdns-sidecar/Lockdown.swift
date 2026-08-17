import Foundation

/// The pf "bypass wall" — ported from nextdns-lockdownd. Asserts our ruleset while armed, keeps the
/// captive-portal door (<local_dns>) tracking the current network, and fails closed (flushes the door)
/// if the Encrypted-DNS profile is removed. Standalone: shells out to pfctl/route/scutil.
enum Lockdown {
    static let marker = "nextdns-lockdown-dns53"        // signature label identifying our ruleset
    static let pfctl  = "/sbin/pfctl"
    static let route  = "/sbin/route"
    static let scutil = "/usr/sbin/scutil"

    static func pfEnabled()      -> Bool { Proc.capture(pfctl, ["-s", "info"]).contains("Status: Enabled") }
    static func pfOursLoaded()   -> Bool { Proc.capture(pfctl, ["-sr"]).contains(marker) }
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
        let red = "\u{1b}[31m", rst = "\u{1b}[0m"
        print("== NextDNS Sidecar :: network lockdown ==")
        print("  state:        " + (isArmedFlag() ? "ARMED (enforcing)" : "disarmed"))
        print("  pf:           " + (pfEnabled() ? "enabled" : "disabled"))
        print("  pf rules:     " + (pfOursLoaded() ? "loaded" : "not loaded"))
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
            let ans = Proc.capture("/usr/bin/dig", ["+time=3", "+tries=1", "@\(server)", "example.com", "+short"])
                .split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            if ans.isEmpty { ok("plain DNS to \(server) is blocked") }
            else if armed { bad("plain DNS to \(server) LEAKS -> \(ans)") }
            else { note("plain DNS to \(server) open (\(ans))") }
        }
        let doh = Proc.capture("/usr/bin/curl", ["-s", "--max-time", "6", "-H", "accept: application/dns-json",
                  "https://1.1.1.1/dns-query?name=example.com&type=A"])
        if doh.isEmpty { ok("DoH to https://1.1.1.1 is blocked") }
        else if armed { bad("DoH to https://1.1.1.1 LEAKS") }
        else { note("DoH to https://1.1.1.1 open") }

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
