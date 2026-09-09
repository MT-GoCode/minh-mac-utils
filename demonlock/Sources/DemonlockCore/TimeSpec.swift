import Foundation

/// The ONE place that parses human time specs and formats durations, shared by every command and
/// slot (snooze, release-valve, snooze-presets, delayed changes). Two input shapes:
///   "for <dur>"        — d/h/m/s tokens, e.g. "for 90m", "for 1h30m"
///   "until <[day]HHMM>" — next occurrence of a wall-clock time, e.g. "until 0730", "until U0730"
///
/// TIMEZONE MODEL (Minh's rule): interpret every input in the CURRENT tz at the moment of parsing,
/// then resolve to an ABSOLUTE instant (a Date / UTC epoch). Callers store the absolute instant, so a
/// later tz change can't slide an already-committed deadline — "it happens at the same moment".
/// Recurring policy windows (TIME_IS_ANY) are a separate concern (evaluated live in current tz); this
/// file only produces frozen instants. (macOS gates tz changes behind admin, and admin-while-armed is
/// itself the thing demonlock gates, so a current-tz read is not a no-sudo bypass.)
enum TimeSpec {

    struct TimeError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Sum of number+unit tokens (d/h/m/s), whitespace-insensitive: "1h30m" → 5400, "90m" → 5400.
    /// nil on a unit with no number, a trailing bare number, or junk.
    static func parseDuration(_ raw: String) -> Double? {
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

    /// Resolve a spec ("for <duration>" | "until <[day]HHMM>") to an absolute future Date (throws).
    static func parseTarget(_ s: String) throws -> Date {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("for") {
            guard let secs = parseDuration(String(trimmed.dropFirst(3))), secs > 0 else {
                throw TimeError(message: "bad duration after 'for' — use e.g. \"for 90m\", \"for 2h\", \"for 1h30m\"")
            }
            return Date().addingTimeInterval(secs)
        }
        if lower.hasPrefix("until") {
            var rest = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces).uppercased()
            var weekday: Int? = nil
            if let first = rest.first, let wd = self.weekday(first), rest.count == 5 {
                weekday = wd; rest = String(rest.dropFirst())
            }
            guard rest.count == 4, rest.allSatisfy(\.isNumber), let v = Int(rest), v <= 2359, v % 100 < 60 else {
                throw TimeError(message: "bad time after 'until' — use \"until HHMM\" or \"until <day>HHMM\" like \"until U0730\"")
            }
            if let wd = weekday {
                // Fail CLOSED: if the calendar can't resolve the day/time, error (no snooze written)
                // rather than silently standing enforcement down for a fallback minute.
                guard let d = nextWeekdayHHMM(weekday: wd, hhmm: v) else {
                    throw TimeError(message: "couldn't resolve \"until\" to a calendar date — try a plain \"until HHMM\"")
                }
                return d
            }
            return nextHHMM(String(format: "%04d", v))
        }
        throw TimeError(message: "expected \"for <duration>\" or \"until <[day]HHMM>\" — e.g. \"for 45m\" or \"until 0730\"")
    }

    /// Next occurrence of an HHMM time-of-day, in the current tz, as an absolute Date.
    static func nextHHMM(_ hhmm: String) -> Date {
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

    /// Day letter → Calendar weekday (1=Sun…7=Sat). M T W R F S U, R=Thu, U=Sun (policy-lang letters).
    static func weekday(_ c: Character) -> Int? {
        switch Character(c.uppercased()) {
        case "U": return 1; case "M": return 2; case "T": return 3; case "W": return 4
        case "R": return 5; case "F": return 6; case "S": return 7; default: return nil
        }
    }

    /// Next strictly-future occurrence of a weekday + HHMM, or nil if the calendar can't resolve it.
    static func nextWeekdayHHMM(weekday: Int, hhmm: Int) -> Date? {
        let cal = Calendar.current, now = Date()
        for off in 0...8 {
            guard let base = cal.date(byAdding: .day, value: off, to: now) else { continue }
            var c = cal.dateComponents([.year, .month, .day], from: base)
            c.hour = hhmm / 100; c.minute = hhmm % 100; c.second = 0
            guard let cand = cal.date(from: c), cand > now, cal.component(.weekday, from: cand) == weekday else { continue }
            return cand
        }
        return nil
    }

    /// A remaining-time string for status/tables: 5400 → "1h30m", 310 → "5m10s", 40 → "40s".
    static func fmtLeft(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h\(m)m" }
        if m > 0 { return "\(m)m\(sec)s" }
        return "\(sec)s"
    }

    /// Render an absolute instant in the current tz for display (tz-aware output; storage stays UTC).
    static func fmtWhen(_ epoch: Double, _ format: String = "EEE yyyy-MM-dd HH:mm") -> String {
        let f = DateFormatter(); f.dateFormat = format
        return f.string(from: Date(timeIntervalSince1970: epoch))
    }
}
