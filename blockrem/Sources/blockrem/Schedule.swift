import Foundation

/// One scheduled block. `durationMin` (5–59) is how long the grey blocker stays up once it fires.
/// A `weekly` alarm recurs on the given weekdays at HHMM; a `onetime` alarm fires once at an
/// absolute instant and is pruned by the daemon after it completes.
struct Alarm: Codable {
    var id: Int
    var label: String
    var durationMin: Int

    enum Kind: Codable {
        case weekly(days: [Int], hhmm: Int)   // weekday ints 1=Sun…7=Sat, HHMM 0000–2359
        case onetime(start: Double)           // absolute epoch of the block's start
    }
    var kind: Kind

    /// If this alarm is blocking at `now`, the epoch when the block ends; else nil.
    func activeEnd(now: Date) -> Double? {
        let dur = Double(durationMin) * 60
        let nowSec = now.timeIntervalSince1970
        switch kind {
        case .onetime(let start):
            return (nowSec >= start && nowSec < start + dur) ? start + dur : nil
        case .weekly(let days, let hhmm):
            let cal = Calendar.current
            // Check today's and yesterday's scheduled start (a window can cross midnight since dur < 60m).
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
            return start + Double(durationMin) * 60 <= now.timeIntervalSince1970
        }
        return false
    }
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
