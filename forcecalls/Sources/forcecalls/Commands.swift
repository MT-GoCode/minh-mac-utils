import Foundation

/// Every command here is user-runnable — NO sudo. The CLI never writes `calls.json`; it drops a
/// marker and the root daemon does the writing. That's what makes a forced call something you have
/// to wait out rather than something you can delete on impulse.
enum Commands {

    // MARK: show

    static func show() {
        let calls = CallStore.load().sorted { $0.id < $1.id }
        let st = DaemonState.load()
        let now = Date()

        if calls.isEmpty {
            print("no forced calls.")
            print("  add one:  forcecalls add --name mom --destination +15559998888 --schedule *2045")
            return
        }

        let nameW = max(4, calls.map(\.name.count).max() ?? 4)
        let destW = max(11, calls.map(\.destination.count).max() ?? 11)
        print("\(pad("ID", 4))\(pad("NAME", nameW + 2))\(pad("DESTINATION", destW + 2))"
              + "\(pad("SCHEDULE", 10))\(pad("ONCE", 6))\(pad("MACHINE", 9))NEXT")
        for c in calls {
            let next = c.schedule.nextOccurrence(now: now).map { fmtWhen($0) } ?? "—"
            print("\(pad(String(c.id), 4))\(pad(c.name, nameW + 2))\(pad(c.destination, destW + 2))"
                  + "\(pad(c.schedule.raw, 10))\(pad(c.once ? "once" : "—", 6))"
                  + "\(pad(c.hangupOnMachine ? "hang up" : "bridge", 9))\(next)")
        }

        let pending = st.pendingRemovals.sorted { $0.applyAt < $1.applyAt }
        if !pending.isEmpty {
            print("\npending removals:")
            for p in pending {
                let left = fmtLeft(p.applyAt - now.timeIntervalSince1970)
                print("  '\(p.name)' lands in \(left)  (\(fmtWhen(p.applyAt)))   — cancel with: forcecalls abort")
            }
        }

        let results = calls.compactMap { c -> String? in
            guard let r = st.lastResult[String(c.id)] else { return nil }
            let when = st.lastResultAt[String(c.id)].map { fmtWhen($0, "MMM d HH:mm") } ?? "?"
            return "  \(pad(c.name, nameW + 2))\(when)  \(r)"
        }
        var attempts = results
        if let r = st.lastResult[kTestKey] {
            let when = st.lastResultAt[kTestKey].map { fmtWhen($0, "MMM d HH:mm") } ?? "?"
            attempts.append("  \(pad("(testcall)", nameW + 2))\(when)  \(r)")
        }
        if !attempts.isEmpty {
            print("\nlast attempt:")
            attempts.forEach { print($0) }
        }
    }

    // MARK: add

    static func add(_ args: [String]) {
        guard let name = flag(args, "--name") else { die("add: --name is required") }
        guard let destRaw = flag(args, "--destination") else { die("add: --destination is required") }
        guard let schedRaw = flag(args, "--schedule") else { die("add: --schedule is required") }

        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { die("add: --name can't be blank") }
        guard !CallStore.load().contains(where: { $0.name == name }) else {
            die("add: a forced call named '\(name)' already exists")
        }
        let once = has(args, "--once")
        let amd = has(args, "--hangup-on-machine")
        let dest: String, spec: ScheduleSpec
        do {
            dest = try validateDestination(destRaw)
            spec = try ScheduleSpec.parse(schedRaw, allowBareTime: once)
        } catch { die("add: \(error)") }

        let req = AddRequest(name: name, destination: dest, schedule: spec.raw,
                             once: once, hangupOnMachine: amd)
        guard let body = try? JSONEncoder().encode(req),
              let text = String(data: body, encoding: .utf8) else { die("add: couldn't encode the request") }
        do { try MarkerIO.drop(kind: "add", body: text) } catch { die("add: \(error)") }

        let next = spec.nextOccurrence(now: Date()).map { fmtWhen($0) } ?? "—"
        print("queued '\(name)' → \(dest) on \(spec.raw)"
              + (once ? " ONCE" : "") + (amd ? " [hang up on voicemail]" : "")
              + "  (\(once ? "fires" : "first call") \(next))")
        print("takes effect within a few seconds — confirm with: forcecalls show")
    }

    // MARK: remove / abort

    static func remove(_ args: [String]) {
        let positional = args.filter { !$0.hasPrefix("--") }
        guard let target = positional.first else {
            die("remove: name it — forcecalls remove <name|id>   (see: forcecalls show)")
        }
        let calls = CallStore.load()
        guard let call = calls.first(where: { $0.name == target || String($0.id) == target }) else {
            die("remove: no forced call named '\(target)' — see: forcecalls show")
        }
        do { try MarkerIO.drop(kind: "remove", body: String(call.id)) } catch { die("remove: \(error)") }

        let delay = Settings.load().removeDelaySec
        print("removal of '\(call.name)' queued — it lands in \(fmtLeft(delay)), not now.")
        print("until then the call still fires. change your mind: forcecalls abort")
    }

    static func abort() {
        do { try MarkerIO.drop(kind: "abort", body: "abort") } catch { die("abort: \(error)") }
        let pending = DaemonState.load().pendingRemovals
        if pending.isEmpty {
            print("nothing was queued — abort recorded anyway.")
        } else {
            print("cancelling \(pending.count) pending removal(s): " + pending.map { "'\($0.name)'" }.joined(separator: ", "))
            print("confirm with: forcecalls show")
        }
    }

    // MARK: testcall

    /// Dial right now, exactly the way 8:45 PM would. Accepts a raw number or the name of a forced
    /// call, so you can rehearse the real thing without waiting for it.
    static func testcall(_ args: [String]) {
        let positional = args.filter { !$0.hasPrefix("--") }
        guard let target = positional.first else {
            die("testcall: give a number or a forced-call name — forcecalls testcall +15559998888")
        }
        let dest: String
        if let known = CallStore.load().first(where: { $0.name == target }) {
            dest = known.destination
        } else {
            do { dest = try validateDestination(target) } catch { die("testcall: \(error)") }
        }
        let amd = has(args, "--hangup-on-machine")
        let req = TestRequest(destination: dest, hangupOnMachine: amd)
        guard let body = try? JSONEncoder().encode(req),
              let text = String(data: body, encoding: .utf8) else { die("testcall: couldn't encode the request") }
        do { try MarkerIO.drop(kind: "testcall", body: text) } catch { die("testcall: \(error)") }
        print("calling \(dest) now\(amd ? " (hanging up if voicemail answers)" : "") — their phone"
              + " rings first, then your endpoint auto-answers.")
        print("outcome shows up in: forcecalls show")
    }

    // MARK: presence

    /// Show what the daemon would decide right now. Without this the presence gate is invisible —
    /// you'd only learn it skipped by reading `show` the next morning.
    static func presence() {
        let s = Settings.load()
        let v = Presence.check(enforcedUser: s.enforcedUser, maxIdle: s.requireActiveSeconds)
        print("console user : \(v.consoleUser ?? "—")   (enforced: \(s.enforcedUser.isEmpty ? "—" : s.enforcedUser))")
        print("idle         : \(v.idleSeconds.map { fmtLeft($0) } ?? "—")")
        print("limit        : \(s.requireActiveSeconds > 0 ? fmtLeft(s.requireActiveSeconds) : "disabled")")
        print("would dial   : \(v.present ? "yes" : "NO — \(v.reason)")")
    }

    // MARK: help

    static func help() {
        print("""
        forcecalls — scheduled calls you have to wait out to cancel.

        At each scheduled time the daemon rings the DESTINATION first; when they answer, your SIP
        endpoint is dialled and auto-answers. Adding is instant; removing is delay-gated.

          forcecalls show
          forcecalls add --name <name> --destination <+E.164> --schedule <DAYS|*><HHMM>
                         [--once] [--hangup-on-machine]
          forcecalls remove <name|id>      queued; lands after the removal delay
          forcecalls abort                 cancel every queued removal
          forcecalls testcall <number|name> [--hangup-on-machine]   dial now, as a scheduled call would
          forcecalls presence              are you active enough for a call to fire right now?
          forcecalls help

        SCHEDULE — days are M T W R F S U (R=Thu, U=Sun) or * for every day, then 4-digit HHMM:

          *2045      every day at 20:45
          MWF0700    Mon/Wed/Fri at 07:00
          U1000      Sundays at 10:00

        --once                fire at the next occurrence of that time, then delete itself. With
                              --once you may give a bare HHMM (e.g. 2045) and skip the day letters.
        --hangup-on-machine   if voicemail or a fax answers, hang up instead of bridging you to a
                              greeting. Adds a couple of seconds of detection before the bridge,
                              and a small per-call detection fee.

        All commands are user-runnable. Only install/uninstall need sudo — that's what makes a
        forced call something you can't simply delete.
        """)
    }

    // MARK: arg parsing

    private static func has(_ args: [String], _ name: String) -> Bool { args.contains(name) }

    private static func flag(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        return v.hasPrefix("--") ? nil : v
    }
}
