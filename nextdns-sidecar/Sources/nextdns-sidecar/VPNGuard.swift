import Foundation
import MacUtilsCore

/// The overlay-resolver guard.
///
/// The wall this tool builds assumes ONE thing: that the system resolver is the NextDNS DoH profile.
/// A VPN/overlay (Tailscale, corp IPSec, anything on a utun) can install itself as the system resolver
/// without any privilege — on macOS `tailscale set --accept-dns` is a menu-bar click — and from then on
/// every query leaves over the tunnel. pf never sees a port-53 packet, the profile stays installed and
/// "healthy", and NextDNS filters nothing. `selftest` reported seven PASS lines over exactly this.
///
/// Worse, the captive-portal door used to *grant* the bypass: `local-dns.txt` shipped `100.64.0.0/10`
/// (which contains Tailscale's 100.100.100.100) and `fc00::/7` (which contains its ULA), and
/// `learnHosts()` scraped every nameserver out of `scutil --dns` — including the overlay's — into
/// <local_dns> on every tick. The wall learned its own bypass and re-punched the hole on every tick.
///
/// This guard identifies overlay resolvers so they can be kept OUT of <local_dns> (the captive-portal
/// door). Once they are out, the ruleset's catch-all `block ... to any port 53` covers them like any
/// other public resolver, so an unprivileged `dig @100.100.100.100` is dropped. Reaching the overlay
/// resolver therefore costs sudo — the same price as every other loosening verb.
enum VPNGuard {
    /// Tailscale's MagicDNS addresses. Fixed constants, so they are also the permanent selftest
    /// probe targets: the IPv6 half of this fix rests on a pf table negation, and probing these
    /// every selftest is what turns that from an assumption into a continuously-checked fact.
    static let knownOverlayResolvers = ["100.100.100.100", "fd7a:115c:a1e0::53"]

    /// Is this a resolver address belonging to the overlay?
    ///
    /// Deliberately narrow. Two wider heuristics were tried and both misfired:
    ///   • the whole 100.64.0.0/10 — that is real-world CGNAT (Starlink, T-Mobile 5G Home, most
    ///     hotel Wi-Fi), so claiming it deletes the network's own resolver from the captive door
    ///     and strands the machine with no way to reach a portal login;
    ///   • "any resolver on a utun interface" — macOS transiently attributes the physical link's
    ///     resolvers to a tunnel block while Tailscale tears its config down, so this fired on
    ///     Comcast's DHCP servers on a perfectly healthy machine.
    /// Tailscale's ULA prefix has three full-width hex groups, so no leading-zero or `::`-compressed
    /// spelling of it exists and a textual prefix match is exact.
    static func isOverlayAddress(_ ip: String) -> Bool {
        ip == "100.100.100.100" || ip.lowercased().hasPrefix("fd7a:115c:a1e0")
    }

    /// IPv6 zone ids (`fe80::1%en0`) are invalid in a pf table — strip them.
    static func stripZone(_ s: String) -> String {
        guard let r = s.range(of: "%") else { return s }
        return String(s[..<r.lowerBound])
    }

    /// The resolvers macOS actually uses for an unscoped query, straight from the dynamic store.
    ///
    /// This is the authoritative source and the only one worth trusting. The `resolver #N` blocks in
    /// `scutil --dns` interleave scoped and supplemental entries with the default one, and reading
    /// them positionally is how a hijacked machine can look clean: an earlier cut decided "is it
    /// scoped?" from each block's `domain` line and counted `search domain[0]` as scoping too. A
    /// search domain is only a suffix macOS *appends* to short names — the resolver still answers
    /// everything — and the hijacking Tailscale entry carries one. Fully bypassed machine, clean bill.
    static func globalResolvers() -> [String] {
        // scutil reads its query from stdin; MacUtilsCore's Proc has no stdin variant, and a fixed
        // literal command needs no more than a shell pipe (nothing here is caller-controlled).
        let out = Proc.capture("/bin/sh", ["-c", "echo 'show State:/Network/Global/DNS' | \(Lockdown.scutil)"])
        var servers: [String] = []
        var inServers = false
        for rawLine in out.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("ServerAddresses") { inServers = true; continue }
            if inServers {
                // scutil always closes an array with `}` alone on its own line, including empty
                // arrays — so this terminator cannot run past the array into other keys.
                if line.hasPrefix("}") { inServers = false; continue }
                if let r = line.range(of: " : ") { servers.append(stripZone(String(line[r.upperBound...]))) }
            }
        }
        return servers
    }

    /// Overlay resolver addresses to keep OUT of the captive door and to probe in selftest.
    static func overlayResolvers() -> [String] {
        Array(Set(knownOverlayResolvers + globalResolvers().filter(isOverlayAddress))).sorted()
    }

    /// Is an overlay resolver serving as the system's DEFAULT resolver? If so every query leaves
    /// over the tunnel, NextDNS sees nothing, and the pf wall is decorative — it can only filter
    /// traffic that goes out as DNS on the physical path.
    static func hijackDetail() -> String? {
        let bad = globalResolvers().filter(isOverlayAddress)
        return bad.isEmpty ? nil : bad.joined(separator: ", ")
    }

    // ---- self-heal ----

    /// Where the Tailscale CLI lives. The GUI (standalone) build ships it inside the app bundle;
    /// the Homebrew/open-source build puts it on PATH.
    static let tailscaleBins = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    /// Force the overlay to stop owning system DNS.
    ///
    /// This is the piece that makes the guarantee hold rather than merely be detected. Turning
    /// Tailscale's DNS back on costs no sudo — it is a menu-bar click — and the pf change alone only
    /// converts that into a *total DNS outage* (the overlay resolver is outside <local_dns>, so its
    /// queries are dropped and nothing resolves at all). An outage is fail-closed but it is not the
    /// requested behaviour: ordinary sites must keep working. So the root daemon reclaims the
    /// resolver instead. Verified that root can drive the user's tailscaled on macOS.
    /// uid → login name, for `sudo -u`. Config stores the enforced user as a numeric uid.
    static func usernameFor(_ uid: uid_t) -> String? {
        guard let p = getpwuid(uid), let n = p.pointee.pw_name else { return nil }
        return String(cString: n)
    }

    /// `uid` is the enforced user — the one whose GUI session owns tailscaled.
    @discardableResult
    static func reclaimDNS(uid: uid_t?) -> Bool {
        let fm = FileManager.default
        guard let bin = tailscaleBins.first(where: { fm.isExecutableFile(atPath: $0) }) else { return false }

        // Getting this invocation right took three tries, so the failures are worth recording:
        //
        //   1. `tailscale set …` straight from the daemon — exits 0, changes NOTHING. A LaunchDaemon
        //      in the `system` domain has no GUI session to reach the app's tailscaled through.
        //   2. `launchctl asuser <uid> tailscale set …` — still fails ("The Tailscale GUI failed to
        //      start: CLIError error 3"). asuser enters the user's session but the command still runs
        //      AS ROOT, and the bundled CLI will not drive another user's GUI agent.
        //   3. `launchctl asuser <uid> sudo -u <name> tailscale set …` — works. Right session AND
        //      right euid. (root's sudo needs no password.)
        //
        // launchctl exits 0 in ALL of the above, including case 2 where it printed an error — so its
        // status is worthless here and the caller must confirm by re-reading state, never by rc.
        let args: [String]
        if let uid = uid, let name = usernameFor(uid) {
            args = ["asuser", String(uid), "/usr/bin/sudo", "-u", name, bin, "set", "--accept-dns=false"]
        } else {
            args = ["asuser", String(getuid()), bin, "set", "--accept-dns=false"]
        }
        Proc.run("/bin/launchctl", args, quiet: true)
        // mDNSResponder caches the resolver config; without this the change lands only on the next
        // network event.
        Proc.run("/usr/bin/dscacheutil", ["-flushcache"], quiet: true)
        Proc.run("/usr/bin/killall", ["-HUP", "mDNSResponder"], quiet: true)
        return true
    }
}
