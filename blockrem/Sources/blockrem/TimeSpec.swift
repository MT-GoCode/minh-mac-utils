import Foundation

/// A human-readable parse failure (so `parseWhen` can hand back a message, not just nil).
struct ParseError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Time parsing shared by the CLI: the `--weekly` token (`<DAYS><HHMM>`), the `--onetime` /
/// `snooze` instant spec (`for <duration>` | `at <[day]HHMM>`), and the day-letter helpers.
/// Day letters follow demonlock: M T W R F S U  (R=Thu, U=Sun). All times are local.
enum TimeSpec {

    // Calendar weekday: 1=Sun … 7=Sat.
    private static let letterToWeekday: [Character: Int] =
        ["U": 1, "M": 2, "T": 3, "W": 4, "R": 5, "F": 6, "S": 7]
    private static let weekdayOrder: [(Character, Int)] =
        [("M", 2), ("T", 3), ("W", 4), ("R", 5), ("F", 6), ("S", 7), ("U", 1)]

    static func weekday(for c: Character) -> Int? { letterToWeekday[Character(c.uppercased())] }

    /// Render a set of weekday ints back to the canonical letter string ("*" when all 7).
    static func letters(for days: [Int]) -> String {
        let set = Set(days)
        if set.count >= 7 { return "*" }
        return weekdayOrder.filter { set.contains($0.1) }.map { String($0.0) }.joined()
    }

    /// HHMM (0000–2359, minutes < 60) as a "9:00 AM"-style string. Pure formatting, no date.
    static func hhmmString(_ hhmm: Int) -> String {
        let h = hhmm / 100, m = hhmm % 100
        let comps = DateComponents(hour: h, minute: m)
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return Calendar.current.date(from: comps).map { f.string(from: $0) } ?? String(format: "%02d:%02d", h, m)
    }

    static func validHHMM(_ v: Int) -> Bool { v >= 0 && v <= 2359 && v % 100 < 60 }

    // MARK: --weekly  <DAYS|*><HHMM>

    /// Parse e.g. "R0800", "*0800", "MWF0730" → (weekday ints, HHMM). nil on any malformation.
    static func parseWeekly(_ raw: String) -> (days: [Int], hhmm: Int)? {
        let s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard s.count >= 5 else { return nil }
        let digits = String(s.suffix(4))
        let dayPart = String(s.dropLast(4))
        guard let hhmm = Int(digits), digits.allSatisfy(\.isNumber), validHHMM(hhmm) else { return nil }
        if dayPart == "*" { return ([1, 2, 3, 4, 5, 6, 7], hhmm) }
        var days: [Int] = []
        for c in dayPart {
            guard let wd = weekday(for: c) else { return nil }
            if !days.contains(wd) { days.append(wd) }
        }
        return days.isEmpty ? nil : (days.sorted(), hhmm)
    }

    // MARK: instant spec  —  "for <duration>"  |  "at <[day]HHMM>"

    /// Resolve an instant spec to an absolute future Date, or a human error.
    static func parseWhen(_ raw: String, now: Date = Date()) -> Result<Date, ParseError> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower.hasPrefix("for") {
            let rest = String(s.dropFirst(3))
            guard let secs = parseDuration(rest), secs > 0 else {
                return .failure(ParseError(message: "bad duration after 'for' — use e.g. \"for 7h 3s\", \"for 30m\", \"for 1h30m\""))
            }
            return .success(now.addingTimeInterval(secs))
        }
        if lower.hasPrefix("at") {
            var rest = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces).uppercased()
            var weekdayFilter: Int? = nil
            if let first = rest.first, letterToWeekday[first] != nil, rest.count == 5 {
                weekdayFilter = letterToWeekday[first]
                rest = String(rest.dropFirst())
            }
            guard rest.count == 4, rest.allSatisfy(\.isNumber), let v = Int(rest), validHHMM(v) else {
                return .failure(ParseError(message: "bad time after 'at' — use \"at HHMM\" or \"at <day>HHMM\" like \"at U0800\""))
            }
            return .success(nextTimeOfDay(hhmm: v, weekday: weekdayFilter, now: now))
        }
        return .failure(ParseError(message: "expected \"for <duration>\" or \"at <[day]HHMM>\" — e.g. \"for 25m\" or \"at U0800\""))
    }

    /// Sum of number+unit tokens (d/h/m/s), whitespace-insensitive: "7h 3s" → 25203, "90m" → 5400.
    /// nil if empty, has a unit without a number, a trailing number without a unit, or junk.
    static func parseDuration(_ raw: String) -> Double? {
        let s = raw.lowercased().filter { !$0.isWhitespace }
        guard !s.isEmpty else { return nil }
        var total = 0.0, num = "", sawUnit = false
        for ch in s {
            if ch.isNumber { num.append(ch); continue }
            guard let n = Double(num) else { return nil }   // unit with no preceding number
            switch ch {
            case "d": total += n * 86400
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
            num = ""; sawUnit = true
        }
        guard num.isEmpty, sawUnit else { return nil }       // trailing bare number, or no units at all
        return total
    }

    /// The next strictly-future occurrence of a time-of-day, optionally constrained to a weekday.
    static func nextTimeOfDay(hhmm: Int, weekday: Int?, now: Date) -> Date {
        let cal = Calendar.current
        for dayOffset in 0...8 {
            guard let base = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            var c = cal.dateComponents([.year, .month, .day], from: base)
            c.hour = hhmm / 100; c.minute = hhmm % 100; c.second = 0
            guard let cand = cal.date(from: c), cand > now else { continue }
            if let wd = weekday, cal.component(.weekday, from: cand) != wd { continue }
            return cand
        }
        return now.addingTimeInterval(60)   // unreachable in practice
    }
}
