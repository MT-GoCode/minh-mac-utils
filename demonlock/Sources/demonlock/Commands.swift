import Foundation

// MARK: - Gate

/// Privileged commands require real root (run via sudo). No osascript-admin path here — the
/// only escalation affordance is the agent's Disarm button.
func requireRoot(_ cmd: String) {
    if geteuid() != 0 {
        FileHandle.standardError.write(Data("demonlock \(cmd): requires sudo — run `sudo demonlock \(cmd) …`\n".utf8))
        exit(1)
    }
}

private func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1)
}

// MARK: - status (user)

func runStatus() {
    guard let s = StateStore.read() else {
        print("demonlock: no state yet — the enforcer isn't running. Install it and `sudo demonlock arm`.")
        return
    }
    let age = nowEpoch() - s.updatedEpoch
    print("demonlock" + (age > 5 ? "  ⚠️  state is \(Int(age))s stale — enforcer may be stuck" : ""))
    print("  enforced user : \(s.enforcedUser.isEmpty ? "(unset)" : s.enforcedUser)")
    print("  armed         : \(s.armed ? "ARMED" : "DISARMED")")
    print("  phase         : \(s.phase.uppercased())")
    if let v = s.verdict { print("  verdict       : \(v.uppercased())") }
    print("  reason        : \(s.reason)")
    if let dl = s.countdownDeadlineEpoch { print("  countdown     : \(max(0, Int(dl - nowEpoch())))s remaining") }
    if let sn = s.snoozeUntilEpoch {
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"
        print("  snooze        : until \(f.string(from: Date(timeIntervalSince1970: sn)))")
    }
    print("  policy        : \(s.policyString.isEmpty ? "(none set)" : s.policyString)")
    if let t = s.tree { print("\n  policy evaluation  (✓ true · ✗ false · · unknown):\n" + t.asText(indent: 2)) }
    if !s.health.locationTrail.isEmpty { print("\n  location:\n" + s.health.locationTrail.joined(separator: "\n")) }
}

// MARK: - zones list (user, no GUI)

func runZoneList() {
    let zones = ZoneStore.load()
    if zones.isEmpty {
        print("no zones yet — create them with `demonlock zones` (the map).")
        return
    }
    let w = zones.map { $0.name.count }.max() ?? 0
    print("demonlock zones (\(zones.count)):")
    for z in zones {
        let pad = z.name.padding(toLength: max(w, 4), withPad: " ", startingAt: 0)
        switch z.shape {
        case .circle(let lat, let lon, let r):
            print(String(format: "  • %@   circle · r%.0fm @ %.5f, %.5f", pad, r, lat, lon))
        case .polygon(let pts):
            print("  • \(pad)   polygon · \(pts.count) points")
        }
    }
    print("\nUse a name verbatim in a policy, e.g. LOCATED_IN_ANY([\"\(zones[0].name)\"]).")
}

// MARK: - setpolicy (sudo)

func runSetPolicy(_ policy: String) {
    requireRoot("setpolicy")
    let p = policy.trimmingCharacters(in: .whitespacesAndNewlines)
    if p.isEmpty { fail("✗ no policy given. Example:\n  sudo demonlock setpolicy '(LOCATED_IN_ANY([\"office\"])) AND TIME_IS_ANY([MTWRF0700-2000])'") }
    let zones = ZoneStore.load()
    do {
        try PolicyEngine.validate(p, zones: zones)
    } catch {
        fail("✗ invalid policy: \(error)")
    }
    do { try PolicyStore.write(p) } catch { fail("✗ couldn't write policy: \(error)") }
    print("✓ policy set:\n  \(p)\n\nRun `demonlock status` to see how it evaluates right now.")
}

// MARK: - snoozetonight (sudo)

func runSnoozeTonight() {
    requireRoot("snoozetonight")
    let target = nextHHMM(Settings.load().snoozeHHMM)
    do { try SnoozeStore.set(target) } catch { fail("✗ couldn't write snooze: \(error)") }
    let f = DateFormatter(); f.dateFormat = "EEE yyyy-MM-dd HH:mm"
    print("✓ snoozed — enforcement stands down until \(f.string(from: target)). The next check after that clears it.")
}

/// Next occurrence of an HHMM time-of-day.
func nextHHMM(_ hhmm: String) -> Date {
    let digits = hhmm.filter(\.isNumber)
    let v = Int(digits) ?? 500
    let h = v / 100, m = v % 100
    let cal = Calendar.current
    let now = Date()
    var comps = cal.dateComponents([.year, .month, .day], from: now)
    comps.hour = h; comps.minute = m; comps.second = 0
    var target = cal.date(from: comps) ?? now
    if target <= now { target = cal.date(byAdding: .day, value: 1, to: target) ?? target }
    return target
}

// MARK: - arm / disarm (sudo)

func runArm() {
    requireRoot("arm")
    do { try ArmStore.set(true) } catch { fail("✗ couldn't arm: \(error)") }
    var note = ""
    if SnoozeStore.until() != nil {            // arming means enforcement is truly live NOW
        try? SnoozeStore.set(nil)
        note = "  (cleared the active snooze)"
    }
    print("✓ ARMED\(note) — the enforcer logs you out after a \(Int(Settings.load().countdownSeconds))s countdown when out of policy. `sudo demonlock disarm` to stop.")
}

func runDisarm() {
    requireRoot("disarm")
    do { try ArmStore.set(false) } catch { fail("✗ couldn't disarm: \(error)") }
    print("✓ DISARMED — everything keeps running and the countdown still shows, but nothing logs you out.")
}

// MARK: - perm-ask (user)

func runPermAsk() {
    print("Demonlock's agent needs Location permission (it runs as your user).")
    if let h = StateStore.read()?.health {
        print("  current: location=\(h.locState), needs-permission=\(h.needsPermAsk ? "YES" : "no")")
    }
    print("Opening System Settings ▸ Privacy & Security ▸ Location Services — turn ON \"Demonlock\".")
    Proc.run("/usr/bin/open", ["x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"])
}

// MARK: - help

func printHelp() {
    print("""
    demonlock — conditional macOS locker

    USAGE: demonlock <command>

    USER COMMANDS (no sudo):
      status              Arm state, phase, verdict, reason, policy, zones, health + live policy tree
      zones               Map of your zones (streets, search, your location). Add a new circle/
                          polygon (needs admin) or Delete one (free — deleting only tightens policy)
      zones list          Print zone names + shapes (no map) — `list-zones` also works
      scan                Continuously scan nearby Wi-Fi (SSID + BSSID) until Ctrl+C —
                          walk your office to capture every access point (run WITHOUT sudo)
      perm-ask            (Re)grant the Location permission the agent needs
      help                This help

    SUDO COMMANDS (require `sudo`):
      setpolicy "<expr>"  Set the allow-policy (validated before it takes effect)
      arm                 Turn enforcement ON
      disarm              Turn enforcement OFF (everything keeps running; countdown just no-ops)
      snoozetonight       Allow everything until the next snooze time (default 05:00)

    POLICY LANGUAGE  (the ALLOW condition — combine with AND / OR / NOT / parentheses):
      LOCATED_IN_ANY(["zone name", ...])
          true when inside any named zone (circle or polygon)
      FOUND_IN_NEARBY_BSSID(["aa:bb:cc:dd:ee:ff", ...])
          true when any pinned access-point hardware address is in range
      TIME_IS_ANY([M0900-1700, *1000-1800, ...])
          true when now is in a window; days M T W R F S U (R=Thu, U=Sun) or * = all 7;
          HHMM 0000-2400, start < end (no midnight wrap — split into two windows)

      example:
        sudo demonlock setpolicy '(LOCATED_IN_ANY(["office"]) OR FOUND_IN_NEARBY_BSSID(["a4:97:33:5f:aa:b6"])) AND TIME_IS_ANY([MTWRF0700-2000])'

    The verdict is three-valued: a missing sensor only blocks you when it actually changes the
    answer — fail-closed only when the policy is genuinely indeterminate.
    """)
}
