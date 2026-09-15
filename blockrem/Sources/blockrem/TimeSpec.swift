import Foundation
import MacUtilsCore

/// Time parsing shared by the CLI: the `--weekly` token (`<DAYS><HHMM>`), the `--onetime` /
/// `snooze` instant spec (`for <duration>` | `at <[day]HHMM>`), and the day-letter helpers.
/// Day letters follow demonlock: M T W R F S U  (R=Thu, U=Sun). All times are local.
extension TimeSpec {

    /// HHMM (0000–2359, minutes < 60) as a "9:00 AM"-style string. Pure formatting, no date.
    static func hhmmString(_ hhmm: Int) -> String {
        let h = hhmm / 100, m = hhmm % 100
        let comps = DateComponents(hour: h, minute: m)
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return Calendar.current.date(from: comps).map { f.string(from: $0) } ?? String(format: "%02d:%02d", h, m)
    }

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
            guard let wd = weekday(c) else { return nil }
            if !days.contains(wd) { days.append(wd) }
        }
        return days.isEmpty ? nil : (days.sorted(), hhmm)
    }

    // MARK: --first-on  <DAYS|*><HHMM>-<HHMM>

    /// Parse e.g. "*0500-0900", "MTWRF0700-1000" → (days, start, end). Requires start < end
    /// (no cross-midnight windows). nil on any malformation.
    static func parseFirstOn(_ raw: String) -> (days: [Int], start: Int, end: Int)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 4, parts[1].allSatisfy(\.isNumber),
              let end = Int(parts[1]), validHHMM(end),
              let head = parseWeekly(String(parts[0])),
              head.hhmm < end
        else { return nil }
        return (head.days, head.hhmm, end)
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
            if let first = rest.first, let wd = weekday(first), rest.count == 5 {
                weekdayFilter = wd
                rest = String(rest.dropFirst())
            }
            // A valid HHMM always resolves within the 8-day search (nil is unreachable) — fail closed anyway.
            guard rest.count == 4, rest.allSatisfy(\.isNumber), let v = Int(rest), validHHMM(v),
                  let d = nextTimeOfDay(hhmm: v, weekday: weekdayFilter, from: now) else {
                return .failure(ParseError(message: "bad time after 'at' — use \"at HHMM\" or \"at <day>HHMM\" like \"at U0800\""))
            }
            return .success(d)
        }
        return .failure(ParseError(message: "expected \"for <duration>\" or \"at <[day]HHMM>\" — e.g. \"for 25m\" or \"at U0800\""))
    }
}
