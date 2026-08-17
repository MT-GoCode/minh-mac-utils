import Foundation

/// A recurring wall-clock instant, written the way demonlock's policy language writes time:
/// `<DAYS|*><HHMM>`, days from the letter alphabet `M T W R F S U` (R=Thu, U=Sun), `*` = every day.
///
///     *2045      every day at 20:45
///     MWF0700    Mon/Wed/Fri at 07:00
///     U1000      Sundays at 10:00
///
/// Unlike demonlock's TIME_IS_ANY windows (which are evaluated live and span a range), this is a
/// single firing instant. Days are stored 1=Mon…7=Sun, matching Policy.swift's dayMap — NOT
/// Calendar's Sunday-first numbering, which is converted at the boundary.
struct ScheduleSpec: Codable, Equatable {
    var days: Set<Int>   // 1=Mon … 7=Sun
    var hhmm: Int        // 0000–2359
    var raw: String      // as typed, uppercased

    static let dayMap: [Character: Int] = ["M": 1, "T": 2, "W": 3, "R": 4, "F": 5, "S": 6, "U": 7]
    static let dayLetters = "MTWRFSU"

    static func parse(_ input: String) throws -> ScheduleSpec {
        let raw = input.trimmingCharacters(in: .whitespaces).uppercased()
        guard !raw.isEmpty else { throw ForceError(message: "empty schedule — use <days>HHMM, e.g. *2045") }
        var idx = raw.startIndex
        var days = Set<Int>()
        if raw.first == "*" {
            days = Set(1...7); idx = raw.index(after: idx)
        } else {
            while idx < raw.endIndex, let d = dayMap[raw[idx]] { days.insert(d); idx = raw.index(after: idx) }
        }
        guard !days.isEmpty else {
            throw ForceError(message: "schedule '\(raw)' must start with day letters (M,T,W,R,F,S,U) or * — e.g. *2045, MWF0700")
        }
        let rest = String(raw[idx...])
        guard rest.count == 4, rest.allSatisfy(\.isNumber), let v = Int(rest) else {
            throw ForceError(message: "schedule '\(raw)' must end with a 4-digit HHMM — e.g. *2045")
        }
        let h = v / 100, m = v % 100
        guard v >= 0, v <= 2359, m < 60, h <= 23 else {
            throw ForceError(message: "schedule '\(raw)': \(String(format: "%04d", v)) is not a valid HHMM (0000–2359)")
        }
        return ScheduleSpec(days: days, hhmm: v, raw: raw)
    }

    /// Calendar weekday (1=Sun…7=Sat) → policy-lang day (1=Mon…7=Sun).
    private static func policyDay(_ calWeekday: Int) -> Int { calWeekday == 1 ? 7 : calWeekday - 1 }

    /// The most recent scheduled instant at or before `now`, or nil if none in the last 8 days.
    /// Used by the daemon to decide "is an occurrence due that we haven't fired yet".
    func mostRecentOccurrence(now: Date) -> Double? {
        let cal = Calendar.current
        var best: Double?
        for off in stride(from: 0, through: -8, by: -1) {
            guard let base = cal.date(byAdding: .day, value: off, to: now) else { continue }
            var c = cal.dateComponents([.year, .month, .day], from: base)
            c.hour = hhmm / 100; c.minute = hhmm % 100; c.second = 0
            guard let cand = cal.date(from: c), cand <= now else { continue }
            guard days.contains(ScheduleSpec.policyDay(cal.component(.weekday, from: cand))) else { continue }
            let e = cand.timeIntervalSince1970
            if best == nil || e > best! { best = e }
        }
        return best
    }

    /// The next strictly-future scheduled instant, for display in `show`.
    func nextOccurrence(now: Date) -> Double? {
        let cal = Calendar.current
        for off in 0...8 {
            guard let base = cal.date(byAdding: .day, value: off, to: now) else { continue }
            var c = cal.dateComponents([.year, .month, .day], from: base)
            c.hour = hhmm / 100; c.minute = hhmm % 100; c.second = 0
            guard let cand = cal.date(from: c), cand > now else { continue }
            guard days.contains(ScheduleSpec.policyDay(cal.component(.weekday, from: cand))) else { continue }
            return cand.timeIntervalSince1970
        }
        return nil
    }
}

/// One forced call: who, what number, when it fires, and two behaviour flags.
struct ForcedCall: Codable {
    var id: Int
    var name: String
    var destination: String     // E.164, e.g. +15559998888
    var schedule: ScheduleSpec
    /// Fire at the next occurrence of the schedule — whatever it is — then delete itself. The
    /// schedule syntax is unchanged: `*0900` is the next 9am, `M0900` the next Monday. Consumed by
    /// a real dial attempt; a presence skip leaves it standing, since "call once" shouldn't be
    /// spent on a night you weren't at the desk.
    var once: Bool
    /// Ask SignalWire to detect an answering machine and hang up instead of bridging you to a
    /// voicemail greeting. Costs a couple of seconds of detection before the bridge.
    var hangupOnMachine: Bool

    init(id: Int, name: String, destination: String, schedule: ScheduleSpec,
         once: Bool = false, hangupOnMachine: Bool = false) {
        self.id = id; self.name = name; self.destination = destination
        self.schedule = schedule; self.once = once; self.hangupOnMachine = hangupOnMachine
    }

    // Lenient: calls.json written before these flags existed decodes with them off.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        destination = try c.decode(String.self, forKey: .destination)
        schedule = try c.decode(ScheduleSpec.self, forKey: .schedule)
        once = (try? c.decode(Bool.self, forKey: .once)) ?? false
        hangupOnMachine = (try? c.decode(Bool.self, forKey: .hangupOnMachine)) ?? false
    }
}

enum CallStore {
    static func load() -> [ForcedCall] { loadJSON(Paths.callsFile) ?? [] }
    static func save(_ calls: [ForcedCall]) { saveJSON(calls, to: Paths.callsFile) }
    static func nextID(_ calls: [ForcedCall]) -> Int { (calls.map(\.id).max() ?? 0) + 1 }
}

/// Destinations must be E.164 — SignalWire rejects anything else, and failing here gives a
/// useful error instead of a 400 at 8:45 PM.
func validateDestination(_ s: String) throws -> String {
    let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
    guard t.hasPrefix("+"), t.count >= 8, t.count <= 17,
          t.dropFirst().allSatisfy(\.isNumber) else {
        throw ForceError(message: "destination '\(s)' must be E.164 — a '+' then digits, e.g. +15559998888")
    }
    return t
}
