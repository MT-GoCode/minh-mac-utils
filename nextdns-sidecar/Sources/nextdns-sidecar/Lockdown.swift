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
        if profilePresent() { print("  DoH profile:  installed") }
        else { print("  DoH profile:  \(red)MISSING\(rst)  (no encrypted resolver — arm is refused)") }
        let resolves = Proc.capture("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", "apple.com"]).contains("ip_address")
        print("  resolution:   " + (resolves ? "working" : "NOT resolving"))
        let daemon = !Proc.capture("/bin/launchctl", ["print", "system/\(Paths.label)"]).isEmpty
        print("  daemon:       " + (daemon ? "loaded" : "NOT loaded"))
    }
}
