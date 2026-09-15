import Foundation

/// A human-readable parse failure (so callers can hand back a message, not just nil).
public struct ParseError: Error, CustomStringConvertible {
    public let message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}

/// Time PRIMITIVES shared by every tool's spec parser. The spec grammars themselves ("for <dur>" +
/// "until|at <[day]HHMM>") stay in each app with their own keyword and error strings — this file
/// only knows durations, HHMM, day letters, and "next occurrence of".
///
/// TIMEZONE MODEL: interpret every input in the CURRENT tz at the moment of parsing, then resolve to
/// an ABSOLUTE instant. Callers store the instant, so a later tz change can't slide a committed
/// deadline. Nothing here caches a DateFormatter — a long-lived daemon must render in the tz it has
/// NOW, not the one it started with.
public enum TimeSpec {

    // MARK: durations

    /// Sum of number+unit tokens (d/h/m/s), whitespace-insensitive: "1h30m" → 5400, "7h 3s" → 25203.
    /// nil if empty, a unit with no preceding number, a trailing bare number, or junk.
    public static func parseDuration(_ raw: String) -> Double? {
        let s = raw.lowercased().filter { !$0.isWhitespace }
        guard !s.isEmpty else { return nil }
        var total = 0.0, num = "", sawUnit = false
        for ch in s {
            if ch.isNumber { num.append(ch); continue }
            guard let n = Double(num) else { return nil }
            switch ch {
            case "d": total += n * 86400
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
            num = ""; sawUnit = true
        }
        guard num.isEmpty, sawUnit else { return nil }
        return total
    }

    // MARK: day letters + HHMM

    /// Day letter → Calendar weekday (1=Sun…7=Sat). M T W R F S U, R=Thu, U=Sun. Case-insensitive.
    public static func weekday(_ c: Character) -> Int? {
        switch Character(c.uppercased()) {
        case "U": return 1; case "M": return 2; case "T": return 3; case "W": return 4
        case "R": return 5; case "F": return 6; case "S": return 7; default: return nil
        }
    }

    private static let weekdayOrder: [(Character, Int)] =
        [("M", 2), ("T", 3), ("W", 4), ("R", 5), ("F", 6), ("S", 7), ("U", 1)]

    /// Render a set of weekday ints back to the canonical letter string ("*" when all 7).
    public static func letters(for days: [Int]) -> String {
        let set = Set(days)
        if set.count >= 7 { return "*" }
        return weekdayOrder.filter { set.contains($0.1) }.map { String($0.0) }.joined()
    }

    public static func validHHMM(_ v: Int) -> Bool { v >= 0 && v <= 2359 && v % 100 < 60 }

    /// The next strictly-future occurrence of a time-of-day, optionally constrained to a weekday,
    /// in `calendar` (default: current tz). nil only if the calendar can't resolve any candidate
    /// within 8 days — callers fail CLOSED on nil (error out), never fall back to a made-up minute.
    public static func nextTimeOfDay(hhmm: Int, weekday: Int?, from now: Date = Date(),
                                     calendar cal: Calendar = .current) -> Date? {
        for dayOffset in 0...8 {
            guard let base = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            var c = cal.dateComponents([.year, .month, .day], from: base)
            c.hour = hhmm / 100; c.minute = hhmm % 100; c.second = 0
            guard let cand = cal.date(from: c), cand > now else { continue }
            if let wd = weekday, cal.component(.weekday, from: cand) != wd { continue }
            return cand
        }
        return nil
    }

    // MARK: formatting

    /// A remaining-time string for status/tables: 5400 → "1h30m", 310 → "5m10s", 40 → "40s".
    public static func fmtLeft(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h\(m)m" }
        if m > 0 { return "\(m)m\(sec)s" }
        return "\(sec)s"
    }

    /// Render an absolute instant in the current tz for display (storage stays UTC).
    public static func fmtWhen(_ epoch: Double, _ format: String = "EEE yyyy-MM-dd HH:mm") -> String {
        let f = DateFormatter(); f.dateFormat = format
        return f.string(from: Date(timeIntervalSince1970: epoch))
    }
}
