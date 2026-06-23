import Foundation

/// Block-length bounds, in SECONDS. The floor avoids accidental flicker-blocks; the ceiling (1h)
/// bounds how long an un-quittable cover can ever sit up — a safety rail, not a usage guide.
let kMinDurationSec = 5
let kMaxDurationSec = 3600

/// One scheduled block. `durationSec` (5–3600) is how long the grey blocker stays up once it fires.
/// A `weekly` alarm recurs on the given weekdays at HHMM; a `onetime` alarm fires once at an
/// absolute instant and is pruned by the daemon after it completes.
struct Alarm: Codable {
    var id: Int
    var label: String
    var durationSec: Int

    enum Kind: Codable {
        case weekly(days: [Int], hhmm: Int)   // weekday ints 1=Sun…7=Sat, HHMM 0000–2359
        case onetime(start: Double)           // absolute epoch of the block's start
    }
    var kind: Kind

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

/// True if `a` and `b` would ever both be blocking at the same instant. Weekly×weekly compares
/// recurring windows on the circular week; any case involving a onetime compares absolute intervals
/// (a onetime spans ≤1h, so for weekly×onetime we only test the weekly's occurrences on the days the
/// onetime touches).
func alarmsOverlap(_ a: Alarm, _ b: Alarm) -> Bool {
    switch (a.kind, b.kind) {
    case let (.onetime(sa), .onetime(sb)):
        return sa < sb + b.duration && sb < sa + a.duration
    case let (.weekly(da, ha), .weekly(db, hb)):
        let pa = da.flatMap { weekSegments(weekOffset(weekday: $0, hhmm: ha), a.duration) }
        let pb = db.flatMap { weekSegments(weekOffset(weekday: $0, hhmm: hb), b.duration) }
        return segmentsIntersect(pa, pb)
    default:
        let weekly = (a.isWeekly ? a : b), once = (a.isWeekly ? b : a)
        guard case let .weekly(days, hhmm) = weekly.kind, case let .onetime(start) = once.kind else { return false }
        let so = start, eo = start + once.duration
        let cal = Calendar.current
        let startDate = Date(timeIntervalSince1970: so)
        for dayOffset in -1...1 {
            guard let base = cal.date(byAdding: .day, value: dayOffset, to: startDate) else { continue }
            var c = cal.dateComponents([.year, .month, .day], from: base)
            c.hour = hhmm / 100; c.minute = hhmm % 100; c.second = 0
            guard let ws = cal.date(from: c) else { continue }
            guard days.contains(cal.component(.weekday, from: ws)) else { continue }
            let s = ws.timeIntervalSince1970, e = s + weekly.duration
            if s < eo && so < e { return true }
        }
        return false
    }
}

private extension Alarm {
    var isWeekly: Bool { if case .weekly = kind { return true }; return false }
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
    static func load() -> [Alarm] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.scheduleFile)),
              let a = try? JSONDecoder().decode([Alarm].self, from: data) else { return [] }
        return a
    }
    static func save(_ alarms: [Alarm]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(alarms) else { return }
        try? data.write(to: URL(fileURLWithPath: Paths.scheduleFile), options: .atomic)
    }
    static func nextID(_ alarms: [Alarm]) -> Int { (alarms.map { $0.id }.max() ?? 0) + 1 }
}

enum SnoozeStore {
    static func until() -> Date? {
        guard let s = try? String(contentsOfFile: Paths.snoozeFile, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != "null", let epoch = Double(t), epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
    static func set(_ date: Date?) throws {
        try (date.map { String($0.timeIntervalSince1970) } ?? "null")
            .write(toFile: Paths.snoozeFile, atomically: true, encoding: .utf8)
    }
}
