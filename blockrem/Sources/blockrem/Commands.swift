import Foundation

// MARK: - helpers

// All subcommands are user-runnable (no sudo): the schedule + snooze live in a user-owned data dir.
// Only install/uninstall need sudo (the app/daemon/plists are root-owned), so you still can't
// uninstall or stop the blocker without your password.

private func fail(_ msg: String) -> Never { errOut(msg); exit(1) }

/// Pull `--key value` pairs out of argv. A flag whose next token is missing or itself a `--flag`
/// is recorded as present-but-empty (callers treat empty as "missing value").
private func parseFlags(_ args: [String]) -> [String: String] {
    var out: [String: String] = [:]
    var i = 0
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if i + 1 < args.count && !args[i + 1].hasPrefix("--") { out[key] = args[i + 1]; i += 2 }
            else { out[key] = ""; i += 1 }
        } else { i += 1 }
    }
    return out
}

private func fmtInstant(_ epoch: Double) -> String {
    let f = DateFormatter(); f.dateFormat = "EEE yyyy-MM-dd h:mm a"
    return f.string(from: Date(timeIntervalSince1970: epoch))
}

// MARK: - list (user)

func runList() {
    let alarms = ScheduleStore.load()
    let now = Date()
    if let sn = SnoozeStore.until(), sn > now {
        print("⏸  snoozed — all blocks suppressed until \(fmtInstant(sn.timeIntervalSince1970))\n")
    }
    if let blk = activeBlock(alarms, now: now) {
        let left = max(0, Int((blk.endsEpoch - now.timeIntervalSince1970).rounded(.up)))
        print("🟥 BLOCKING NOW: \"\(blk.label)\" — \(left)s left\n")
    }
    if alarms.isEmpty { print("no alarms set — add one with `blockrem set …` (see `blockrem help`)."); return }
    print("blockrem alarms (\(alarms.count)):")
    for a in alarms.sorted(by: { $0.id < $1.id }) {
        let when: String
        switch a.kind {
        case .weekly(let days, let hhmm):
            when = "weekly  \(TimeSpec.letters(for: days)) \(TimeSpec.hhmmString(hhmm))"
        case .onetime(let start):
            when = "once    \(fmtInstant(start))"
        }
        print(String(format: "  [%d]  %-32@  %5ds   \"%@\"", a.id, when as NSString, a.durationSec, a.label))
    }
}

// MARK: - set (user)

func runSet(_ args: [String]) {
    let f = parseFlags(args)
    let hasWeekly = f["weekly"] != nil, hasOnetime = f["onetime"] != nil
    guard hasWeekly != hasOnetime else {
        fail("✗ give exactly one of --weekly or --onetime.\n" + usageSet)
    }
    guard let label = f["label"], !label.trimmingCharacters(in: .whitespaces).isEmpty else {
        fail("✗ --label \"…\" is required.\n" + usageSet)
    }
    guard let durStr = f["duration"], let dur = Int(durStr) else {
        fail("✗ --duration <seconds> is required.\n" + usageSet)
    }
    guard dur >= kMinDurationSec && dur <= kMaxDurationSec else {
        fail("✗ --duration must be an integer \(kMinDurationSec)–\(kMaxDurationSec) (seconds). Got \(dur).")
    }

    let kind: Alarm.Kind
    if hasWeekly {
        guard let parsed = TimeSpec.parseWeekly(f["weekly"] ?? "") else {
            fail("✗ --weekly must be <DAYS|*><HHMM>, e.g. R0800, *0800, MWF0730 (days M T W R F S U, R=Thu U=Sun).")
        }
        kind = .weekly(days: parsed.days, hhmm: parsed.hhmm)
    } else {
        switch TimeSpec.parseWhen(f["onetime"] ?? "") {
        case .failure(let why): fail("✗ --onetime \(why)")
        case .success(let start): kind = .onetime(start: start.timeIntervalSince1970)
        }
    }

    var alarms = ScheduleStore.load()
    let id = ScheduleStore.nextID(alarms)
    let candidate = Alarm(id: id, label: label, durationSec: dur, kind: kind)
    if let clash = alarms.first(where: { alarmsOverlap($0, candidate) }) {
        fail("✗ that overlaps existing alarm [\(clash.id)] \"\(clash.label)\" — delete it (blockrem delete \(clash.id)) or pick a non-overlapping time.")
    }
    alarms.append(candidate)
    ScheduleStore.save(alarms)

    switch kind {
    case .weekly(let d, let hhmm):
        print("✓ added [\(id)] weekly \(TimeSpec.letters(for: d)) \(TimeSpec.hhmmString(hhmm)) for \(dur)s — \"\(label)\"")
    case .onetime(let start):
        print("✓ added [\(id)] once \(fmtInstant(start)) for \(dur)s — \"\(label)\"")
    }
}

// MARK: - delete (user)

func runDelete(_ args: [String]) {
    guard let idStr = args.first(where: { Int($0) != nil }), let id = Int(idStr) else {
        fail("✗ usage: blockrem delete <id>   (see `blockrem list`)")
    }
    var alarms = ScheduleStore.load()
    guard alarms.contains(where: { $0.id == id }) else { fail("✗ no alarm with id \(id). See `blockrem list`.") }
    alarms.removeAll { $0.id == id }
    ScheduleStore.save(alarms)
    print("✓ deleted alarm \(id)")
}

// MARK: - snooze (user)

func runSnooze(_ args: [String]) {
    let spec = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    guard !spec.isEmpty else {
        fail("✗ usage: blockrem snooze \"for <duration>\" | \"at <[day]HHMM>\"\n" +
             "  e.g. blockrem snooze \"for 90m\"   ·   blockrem snooze \"at U0800\"")
    }
    switch TimeSpec.parseWhen(spec) {
    case .failure(let why): fail("✗ \(why)")
    case .success(let until):
        do { try SnoozeStore.set(until) } catch { fail("✗ couldn't write snooze: \(error)") }
        print("✓ snoozed — all blocks suppressed until \(fmtInstant(until.timeIntervalSince1970)).")
    }
}

// MARK: - perm-ask (user)

func runPermAsk() {
    print("blockrem blocks input with a CGEvent tap, which needs the Accessibility permission.")
    print("Opening System Settings ▸ Privacy & Security ▸ Accessibility — turn ON \"Blockrem\".")
    Proc.run("/usr/bin/open", ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])
}

// MARK: - help

private let usageSet = """
USAGE:
  blockrem set --weekly <DAYS|*><HHMM> --label "…" --duration <5-3600>
  blockrem set --onetime "for <dur>" | "at <[day]HHMM>" --label "…" --duration <5-3600>
  (--duration is the block length in SECONDS, 5–3600)
"""

func printHelp() {
    print("""
    blockrem — scheduled, un-quittable screen blocks (forced breaks/reminders)

    At each scheduled time a grey opaque cover fills every display with your label and a live
    countdown. It re-maximizes itself every tick, sits above everything, refuses Cmd-Q, and is
    relaunched by a root daemon if you kill it — so you can't click or quit it away. With
    Accessibility granted it also freezes keyboard + mouse for the block's duration. All times LOCAL.

    Managing alarms is FREE (no sudo); only install/uninstall need sudo — that's what makes the
    overlay un-quittable (root owns the daemon that revives it) and the tool un-removable.

    COMMANDS (all user-runnable — no sudo):
      list                 All alarms, the active block, and any snooze
      set --weekly <DAYS|*><HHMM> --label "…" --duration <5-3600>
                           Recurring block. Days: M T W R F S U (R=Thu, U=Sun) or * = every day.
                           e.g.  blockrem set --weekly *0800 --label "water break" --duration 30
                                 blockrem set --weekly MWF1230 --label "lunch, walk" --duration 300
      set --onetime "<for…|at…>" --label "…" --duration <5-3600>
                           One-shot block; the spec is WHEN it STARTS (still needs --duration):
                             "for 7h 3s" → starts that long from now   (units d/h/m/s)
                             "at U0800"  → starts next Sunday 08:00
                             "at 0930"   → starts the next time it's 09:30
                           e.g.  blockrem set --onetime "at 1400" --label "standup" --duration 120
      delete <id>          Remove an alarm by id (from `list`)
      snooze "<for…|at…>"  Suppress ALL blocks until that instant (same spec as --onetime)
                           e.g.  blockrem snooze "for 90m"   ·   blockrem snooze "at U0800"
      perm-ask             Open Accessibility settings (needed to freeze keyboard/mouse)
      help                 This help

    --duration is the block LENGTH in SECONDS (5–3600). The onetime/snooze "for <dur>" spec is a
    DIFFERENT thing — how far ahead the instant is — and accepts d/h/m/s. `set` refuses an alarm
    whose window overlaps an existing one.
    """)
}
