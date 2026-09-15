import Foundation
import MacUtilsCore

/// Block-length bounds, in SECONDS. The floor avoids accidental flicker-blocks; the ceiling (1h)
/// bounds how long an un-quittable cover can ever sit up — a safety rail, not a usage guide.
let kMinDurationSec = 5
let kMaxDurationSec = 3600

/// One scheduled block. `durationSec` (5–3600) is how long the grey blocker stays up once it fires.
/// A `weekly` alarm recurs on the given weekdays at HHMM; a `onetime` alarm fires once at an
/// absolute instant and is pruned by the daemon after it completes; a `firstOn` alarm fires once
/// per listed day at the first instant inside [start, end) that the machine is in use.
struct Alarm: Codable {
    var id: Int
    var label: String
    var durationSec: Int

    enum Kind: Codable {
        case weekly(days: [Int], hhmm: Int)   // weekday ints 1=Sun…7=Sat, HHMM 0000–2359
        case onetime(start: Double)           // absolute epoch of the block's start
        case firstOn(days: [Int], startHHMM: Int, endHHMM: Int)   // window [start, end), local, same-day
    }
    var kind: Kind

    /// firstOn only: epoch of today's fire, doubling as the once-per-day latch and the block's
    /// start. Persisted for restart survival, but the daemon's in-memory copy is authoritative
    /// (a silently failed save must never allow a refire).
    var lastFiredEpoch: Double? = nil

    var duration: Double { Double(durationSec) }

    /// If this alarm is blocking at `now`, the epoch when the block ends; else nil.
    func activeEnd(now: Date) -> Double? {
        let dur = duration
        let nowSec = now.timeIntervalSince1970
        switch kind {
        case .onetime(let start):
            return (nowSec >= start && nowSec < start + dur) ? start + dur : nil
        case .weekly(let days, let hhmm):
            let cal = Calendar.current
            // Check today's and yesterday's scheduled start (a window can cross midnight since dur ≤ 1h).
            for dayOffset in [0, -1] {
                guard let base = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
                var c = cal.dateComponents([.year, .month, .day], from: base)
                c.hour = hhmm / 100; c.minute = hhmm % 100; c.second = 0
                guard let start = cal.date(from: c) else { continue }
                guard days.contains(cal.component(.weekday, from: start)) else { continue }
                let s = start.timeIntervalSince1970
                if nowSec >= s && nowSec < s + dur { return s + dur }
            }
            return nil
        case .firstOn:
            guard let fired = lastFiredEpoch else { return nil }
            return (nowSec >= fired && nowSec < fired + dur) ? fired + dur : nil
        }
    }

    /// True once a onetime alarm's window is entirely in the past (so the daemon can prune it).
    func isExpiredOnetime(now: Date) -> Bool {
        if case .onetime(let start) = kind {
            return start + duration <= now.timeIntervalSince1970
        }
        return false
    }
}

// MARK: - overlap detection (so `set` can refuse a clashing alarm)

private let kWeekSeconds = 604800.0

/// Seconds from the start of the week (Sunday 00:00) for a (weekday, HHMM). weekday 1=Sun…7=Sat.
private func weekOffset(weekday: Int, hhmm: Int) -> Double {
    Double((weekday - 1) * 86400) + Double(hhmm / 100) * 3600 + Double(hhmm % 100) * 60
}

/// Split a [start, start+dur) interval into ≤2 in-week segments, wrapping past the week boundary.
private func weekSegments(_ start: Double, _ dur: Double) -> [(Double, Double)] {
    let s = start.truncatingRemainder(dividingBy: kWeekSeconds)
    let e = s + dur
    return e <= kWeekSeconds ? [(s, e)] : [(s, kWeekSeconds), (0, e - kWeekSeconds)]
}

private func segmentsIntersect(_ p: [(Double, Double)], _ q: [(Double, Double)]) -> Bool {
    for a in p { for b in q where a.0 < b.1 && b.0 < a.1 { return true } }
    return false
}

private func hhmmSeconds(_ hhmm: Int) -> Double {
    Double(hhmm / 100) * 3600 + Double(hhmm % 100) * 60
}

/// For recurring kinds, the (days, start HHMM, occupied seconds) each occurrence spans. A firstOn
/// can fire anywhere in its window, so it conservatively occupies window + block length.
private func recurringDaily(_ a: Alarm) -> (days: [Int], startHHMM: Int, span: Double)? {
    switch a.kind {
    case .onetime: return nil
    case .weekly(let days, let hhmm): return (days, hhmm, a.duration)
    case .firstOn(let days, let s, let e):
        return (days, s, hhmmSeconds(e) - hhmmSeconds(s) + a.duration)
    }
}

private func recurringSegments(_ a: Alarm) -> [(Double, Double)] {
    guard let d = recurringDaily(a) else { return [] }
    return d.days.flatMap { weekSegments(weekOffset(weekday: $0, hhmm: d.startHHMM), d.span) }
}

/// Does recurring alarm `rec`'s occupied span ever intersect the absolute interval [so, eo)?
/// Only the days the interval touches matter (span ≤ ~25h, so offsets -1…1 suffice).
private func recurringHitsInterval(_ rec: Alarm, _ so: Double, _ eo: Double) -> Bool {
    guard let d = recurringDaily(rec) else { return false }
    let cal = Calendar.current
    let startDate = Date(timeIntervalSince1970: so)
    for dayOffset in -1...1 {
        guard let base = cal.date(byAdding: .day, value: dayOffset, to: startDate) else { continue }
        var c = cal.dateComponents([.year, .month, .day], from: base)
        c.hour = d.startHHMM / 100; c.minute = d.startHHMM % 100; c.second = 0
        guard let ws = cal.date(from: c) else { continue }
        guard d.days.contains(cal.component(.weekday, from: ws)) else { continue }
        let s = ws.timeIntervalSince1970, e = s + d.span
        if s < eo && so < e { return true }
    }
    return false
}

/// True if `a` and `b` would ever both be blocking at the same instant. Recurring×recurring
/// compares occupied spans on the circular week; any case involving a onetime compares absolute
/// intervals. Exhaustive over kind pairs — no `default`, so the compiler flags any future kind.
func alarmsOverlap(_ a: Alarm, _ b: Alarm) -> Bool {
    switch (a.kind, b.kind) {
    case let (.onetime(sa), .onetime(sb)):
        return sa < sb + b.duration && sb < sa + a.duration
    case (.onetime(let start), .weekly), (.onetime(let start), .firstOn):
        return recurringHitsInterval(b, start, start + a.duration)
    case (.weekly, .onetime(let start)), (.firstOn, .onetime(let start)):
        return recurringHitsInterval(a, start, start + b.duration)
    case (.weekly, .weekly), (.weekly, .firstOn), (.firstOn, .weekly), (.firstOn, .firstOn):
        return segmentsIntersect(recurringSegments(a), recurringSegments(b))
    }
}

// MARK: - first-on latch merge (pure, so `_selftest` can exercise it)

/// Two-way merge of the daemon's memory-authoritative fired map with the on-disk latches:
/// memory survives a silently failed save or a CLI write that clobbered `lastFiredEpoch`
/// (either would otherwise refire — the rolling-block BLOCKER); disk survives a daemon restart
/// (else a restart mid-day double-fires — confirm-pass N1). Ids absent from `alarms` are
/// dropped (deleted alarm loses its latch). `mutated` = disk needs a re-persist.
func mergeFirstOnLatches(fired: [Int: Double], alarms: [Alarm])
    -> (fired: [Int: Double], alarms: [Alarm], mutated: Bool) {
    var fired = fired, alarms = alarms, mutated = false
    let liveIDs = Set(alarms.map { $0.id })
    fired = fired.filter { liveIDs.contains($0.key) }
    for i in alarms.indices {
        guard case .firstOn = alarms[i].kind else { continue }
        let merged = max(fired[alarms[i].id] ?? 0, alarms[i].lastFiredEpoch ?? 0)
        guard merged > 0 else { continue }
        fired[alarms[i].id] = merged
        if alarms[i].lastFiredEpoch != merged { alarms[i].lastFiredEpoch = merged; mutated = true }
    }
    return (fired, alarms, mutated)
}

// MARK: - first-on trigger (pure, so `_selftest` can exercise it)

/// Should this `.firstOn` alarm fire at `now`? `alarm.lastFiredEpoch` must already carry the
/// daemon's merged (memory-authoritative) latch. The daemon calls this only past its snooze
/// early-return, but the parameter keeps the full gate testable.
func firstOnShouldFire(_ alarm: Alarm, now: Date, inUse: Bool, snoozedUntil: Double?) -> Bool {
    guard case let .firstOn(days, startHHMM, endHHMM) = alarm.kind else { return false }
    if let sn = snoozedUntil, now.timeIntervalSince1970 < sn { return false }
    guard inUse else { return false }
    let cal = Calendar.current
    guard days.contains(cal.component(.weekday, from: now)) else { return false }
    let hm = cal.component(.hour, from: now) * 100 + cal.component(.minute, from: now)
    guard hm >= startHHMM && hm < endHHMM else { return false }
    if let fired = alarm.lastFiredEpoch,
       cal.isDate(Date(timeIntervalSince1970: fired), inSameDayAs: now) { return false }
    return true
}

/// The currently-winning block (latest-ending of any overlapping alarms), if any.
func activeBlock(_ alarms: [Alarm], now: Date) -> (label: String, endsEpoch: Double)? {
    var best: (String, Double)?
    for a in alarms {
        guard let end = a.activeEnd(now: now) else { continue }
        if best == nil || end > best!.1 { best = (a.label, end) }
    }
    return best
}

enum ScheduleStore {
    static func load() -> [Alarm] { loadJSON(Paths.scheduleFile) ?? [] }
    static func save(_ alarms: [Alarm]) { saveJSON(alarms, to: Paths.scheduleFile, pretty: true) }
    static func nextID(_ alarms: [Alarm]) -> Int { (alarms.map { $0.id }.max() ?? 0) + 1 }
}

enum SnoozeStore {
    static func until() -> Date? { EpochFile.read(Paths.snoozeFile) }
    static func set(_ date: Date?) throws { try EpochFile.write(date, to: Paths.snoozeFile) }
}
