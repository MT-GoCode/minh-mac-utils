import Foundation

// nextdns-sidecar — merged NextDNS self-discipline tool (list manager + DNS-bypass lockdown).
//
// SUDO-GATING (demonlock convention):
//   • TIGHTENING + status + delayed-requests → NO sudo (drop a user marker / read-only).
//   • LOOSENING (immediate allow, disarm) or config change (set-delay) → sudo (runs as root directly).
// The root daemon owns all state and does the privileged work; user commands drop owner-checked markers.

let argv = Array(CommandLine.arguments.dropFirst())

switch argv.first ?? "help" {
case "enforcerd":                          Daemon().run()
case "domains":                            runDomains(Array(argv.dropFirst()))
case "networklockdown", "lockdown":        runNetworkLockdown(Array(argv.dropFirst()))
case "set-delay":                          runSetDelay(argv.dropFirst().joined(separator: " "))
case "help", "--help", "-h":               printHelp()
default:                                   printHelp(); exit(2)
}

// MARK: - domains  (block / add / delay-add / abort / future)

func runDomains(_ a: [String]) {
    let doms = Array(a.dropFirst())
    switch a.first {
    case "block":      cmdBlock(doms)
    case "add":        cmdAdd(doms)
    case "delay-add":  cmdDelayAdd(doms)
    case "abort":      cmdAbort(doms)
    case "future":     cmdFuture()
    case "test":       cmdTest(doms)
    default:
        fail("""
        usage:
          nextdns-sidecar domains block <domain>... | -f FILE     # block now (no sudo)
          sudo nextdns-sidecar domains add <domain>... | -f FILE  # allow now (sudo)
          nextdns-sidecar domains delay-add <domain>... | -f FILE # allow after the delay (no sudo)
          nextdns-sidecar domains abort <domain> | --all          # cancel queued delayed allow(s)
          nextdns-sidecar domains future                          # list pending delayed allows
          nextdns-sidecar domains test [--blocked|--allowed] <domain>... | -f FILE   # is it blocked?
        """)
    }
}

/// Expand CLI args into a domain list: `-f FILE` (one domain per line, `#` comments) plus positionals.
func collectDomains(_ args: [String]) -> [String] {
    var out: [String] = []; var i = 0
    while i < args.count {
        if args[i] == "-f" {
            i += 1
            guard i < args.count else { fail("error: -f needs a file path") }
            guard let text = try? String(contentsOfFile: args[i], encoding: .utf8) else { fail("error: can't read file: \(args[i])") }
            for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                var s = String(line)
                if let h = s.firstIndex(of: "#") { s = String(s[..<h]) }
                s = s.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { out.append(s) }
            }
        } else {
            out.append(args[i])
        }
        i += 1
    }
    return out
}

/// block — no sudo, immediate tighten. Drops a marker; the daemon calls the API next tick.
func cmdBlock(_ ds: [String]) {
    let doms = collectDomains(ds).filter { !$0.isEmpty }
    guard !doms.isEmpty else { fail("usage: nextdns-sidecar domains block <domain>... | -f FILE") }
    for d in doms where !validDomain(d) { fail("error: invalid domain: \(d)") }
    dropMarker(Paths.mBlock, doms.joined(separator: "\n"))
    print("✓ block queued for \(doms.count) domain(s) — applies within a few seconds (daemon).")
}

/// add — sudo, immediate allow. Runs as root, reads creds, calls the API directly (like nextdns-allow).
func cmdAdd(_ ds: [String]) {
    guard geteuid() == 0 else { fail("nextdns-sidecar domains add: must run as root — use `sudo nextdns-sidecar domains add ...`") }
    let doms = collectDomains(ds).filter { !$0.isEmpty }
    guard !doms.isEmpty else { fail("usage: sudo nextdns-sidecar domains add <domain>... | -f FILE") }
    for d in doms where !validDomain(d) { fail("error: invalid domain: \(d)") }
    guard let api = NextDNSAPI.load() else { fail("error: cannot read credentials at \(Paths.credFile) (run the installer)") }
    var failures = 0
    for d in doms {
        let r = api.allow(d)
        print("allow  \(d.padding(toLength: max(d.count, 40), withPad: " ", startingAt: 0)) allowlist+=\(r.add) denylist-=\(r.rm)  \(r.ok ? "OK" : "FAILED")")
        if !r.ok { failures += 1 }
    }
    if failures > 0 { fail("add: \(doms.count - failures)/\(doms.count) succeeded, \(failures) FAILED") }
    print("add: \(doms.count)/\(doms.count) succeeded")
}

/// delay-add — no sudo, lands after the (root-configured, Bounds-clamped) delay.
func cmdDelayAdd(_ ds: [String]) {
    let doms = collectDomains(ds).filter { !$0.isEmpty }
    guard !doms.isEmpty else { fail("usage: nextdns-sidecar domains delay-add <domain>... | -f FILE") }
    for d in doms where !validDomain(d) { fail("error: invalid domain: \(d)") }
    dropMarker(Paths.mDelayAdd, doms.joined(separator: "\n"))
    let h = Int(Config.load().clampedDelay / 3600)
    print("✓ delay-add queued for \(doms.count) domain(s) — the allow lands in ~\(h)h, NO sudo needed then.")
    print("  view: nextdns-sidecar domains future   cancel: nextdns-sidecar domains abort <domain> | --all")
}

/// abort — no sudo, tightening. Cancel a queued delayed allow by domain, or all of them.
func cmdAbort(_ ds: [String]) {
    let doms = ds.filter { !$0.isEmpty }
    if doms.isEmpty || doms.contains("--all") {
        dropMarker(Paths.mAbort, "--all")
        print("✓ aborting ALL queued delayed allows (applies next tick).")
    } else {
        for d in doms where !validDomain(d) { fail("error: invalid domain: \(d)") }
        dropMarker(Paths.mAbort, doms.joined(separator: "\n"))
        print("✓ aborting queued delayed allow(s): \(doms.joined(separator: " ")) (applies next tick).")
    }
}

/// future — no sudo, read-only. Pending delayed ADDS only (not the whole NextDNS domain list).
func cmdFuture() {
    let reg = Registry.load()
    if reg.pending.isEmpty { print("delay-add: nothing queued."); return }
    let now = nowEpoch()
    let f = DateFormatter(); f.dateFormat = "EEE yyyy-MM-dd HH:mm"
    print("pending delayed allows (\(reg.pending.count)):")
    for (d, p) in reg.pending.sorted(by: { $0.key < $1.key }) {
        let left = max(0, Int(p.applyAt - now))
        print("  \(d.padding(toLength: max(d.count, 40), withPad: " ", startingAt: 0)) lands \(f.string(from: Date(timeIntervalSince1970: p.applyAt)))  (\(left / 3600)h \(left % 3600 / 60)m left)")
    }
}

/// test — no sudo, read-only. Resolve each domain through the SYSTEM resolver and report BLOCKED vs
/// ALLOWED. Restores nextdns-test with the profile-mode fix (system resolver, not `dig @127.0.0.1`).
func cmdTest(_ ds: [String]) {
    var filter = "all", raw: [String] = [], i = 0
    while i < ds.count {
        switch ds[i] {
        case "--blocked": filter = "blocked"
        case "--allowed": filter = "allowed"
        case "--all":     filter = "all"
        case "-f":        i += 1; guard i < ds.count else { fail("error: -f needs a file path") }; raw += ["-f", ds[i]]
        default:          raw.append(ds[i])
        }
        i += 1
    }
    let doms = collectDomains(raw).filter { !$0.isEmpty }
    guard !doms.isEmpty else { fail("usage: nextdns-sidecar domains test [--blocked|--allowed] <domain>... | -f FILE") }
    var nb = 0, na = 0
    for d in doms {
        let blocked = Lockdown.isBlocked(d)
        if blocked { nb += 1 } else { na += 1 }
        if filter == "all" || (filter == "blocked" && blocked) || (filter == "allowed" && !blocked) {
            print("\((blocked ? "BLOCKED" : "ALLOWED").padding(toLength: 8, withPad: " ", startingAt: 0)) \(d)")
        }
    }
    FileHandle.standardError.write(Data("tested \(doms.count): \(nb) blocked, \(na) allowed\n".utf8))
}

// MARK: - networklockdown  (arm / disarm / status / selftest / reload)

func runNetworkLockdown(_ a: [String]) {
    switch a.first ?? "status" {
    case "arm":      cmdArm()
    case "disarm":   cmdDisarm()
    case "status":   Lockdown.printStatus()
    case "selftest": Lockdown.selfTest()
    case "reload":   cmdReload()
    default:         fail("usage: nextdns-sidecar networklockdown {arm|disarm|status|selftest|reload}")
    }
}

/// reload — sudo. Re-validate + reload the pf ruleset after editing the on-disk tables.
func cmdReload() {
    guard geteuid() == 0 else { fail("nextdns-sidecar networklockdown reload: requires root — `sudo nextdns-sidecar networklockdown reload`") }
    Lockdown.reload()
}

/// arm — no sudo, tightening. Client-side refuses if the DoH profile is missing (would strand DNS),
/// then drops the arm marker; the daemon creates the root-owned armed flag (re-checking the profile).
func cmdArm() {
    if !Lockdown.profilePresent() {
        fail("""
        ✗ refusing to arm: the NextDNS Encrypted-DNS profile is not installed.
          Arming blocks every other DNS path, so with no encrypted resolver you'd have a total outage.
          Install the profile (System Settings ▸ General ▸ Device Management), confirm with
          `nextdns-sidecar networklockdown status`, then re-run `nextdns-sidecar networklockdown arm`.
        """)
    }
    if !Lockdown.resolvesSystem() {
        fail("""
        ✗ refusing to arm: DNS isn't resolving right now (mid captive-portal login?).
          Arming blocks every public DNS path, so arming now could strand you. Get online normally
          first, confirm a website loads, then re-run `nextdns-sidecar networklockdown arm`.
        """)
    }
    dropMarker(Paths.mArm)
    print("✓ arm requested — enforcement asserts within a few seconds.")
    print("  Verify with:  nextdns-sidecar networklockdown status")
}

/// disarm — sudo, loosening. Runs as root: removes the armed flag AND tears pf down NOW (works even if
/// the daemon is wedged). The Encrypted-DNS profile is untouched, so DNS stays filtered.
func cmdDisarm() {
    guard geteuid() == 0 else { fail("nextdns-sidecar networklockdown disarm: requires root — `sudo nextdns-sidecar networklockdown disarm`") }
    try? FileManager.default.removeItem(atPath: Paths.armedFile)
    Proc.run(Lockdown.pfctl, ["-t", "local_dns", "-T", "flush"])
    Proc.run(Lockdown.pfctl, ["-f", "/etc/pf.conf"])
    Proc.run(Lockdown.pfctl, ["-d"])
    print("Disarmed — pf restored to macOS defaults now (not on a delay).")
    print("The NextDNS Encrypted-DNS profile is untouched, so DNS keeps being filtered.")
}

// MARK: - set-delay  (sudo — config change)

/// set-delay "<dur>" — sudo. Sets the delay-add landing delay, clamped into Bounds.addDelay [8h,168h].
func runSetDelay(_ s: String) {
    guard geteuid() == 0 else { fail("nextdns-sidecar set-delay: requires root — `sudo nextdns-sidecar set-delay \"12h\"`") }
    guard let secs = parseDuration(s), secs > 0 else { fail("bad duration — use e.g. \"12h\", \"1d\", \"8h30m\"") }
    let clamped = Bounds.clamp(secs, Bounds.addDelay)
    var c = Config.load(); c.delaySec = clamped
    do { try c.save() } catch { fail("error: couldn't write \(Paths.configFile): \(error)") }
    let note = clamped != secs ? "  (clamped into [8h, 168h])" : ""
    print("delay-add landing delay set to \(Int(clamped / 3600))h\(note).")
}

// MARK: - help

func printHelp() {
    print("""
    nextdns-sidecar — NextDNS self-discipline: list manager + DNS-bypass lockdown.

    domains (NextDNS denylist/allowlist):
      nextdns-sidecar domains block <domain>...        block now                 (no sudo)
      sudo nextdns-sidecar domains add <domain>...     allow now                 (sudo — loosening)
      nextdns-sidecar domains delay-add <domain>...    allow after the delay     (no sudo)
      nextdns-sidecar domains abort <domain> | --all   cancel queued delayed allow(s)
      nextdns-sidecar domains future                   list pending delayed allows
      nextdns-sidecar domains test <domain>...         is it blocked? (also -f FILE, --blocked/--allowed)

    networklockdown (pf wall forcing DNS through the NextDNS DoH profile):
      nextdns-sidecar networklockdown arm              enforce                   (no sudo — tightening)
      sudo nextdns-sidecar networklockdown disarm      stop enforcing            (sudo — loosening)
      nextdns-sidecar networklockdown status           show state                (no sudo)
      nextdns-sidecar networklockdown selftest         probe bypass vectors      (no sudo)
      sudo nextdns-sidecar networklockdown reload      re-load pf after edits    (sudo)

    config:
      sudo nextdns-sidecar set-delay "<dur>"           delay-add delay, e.g. "12h" (clamped 8h–168h)
    """)
}
