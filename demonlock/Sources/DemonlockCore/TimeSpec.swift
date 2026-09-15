import Foundation
import MacUtilsCore

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
extension TimeSpec {

    struct TimeError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Resolve a spec ("for <duration>" | "until <[day]HHMM>") to an absolute future Date (throws).
    static func parseTarget(_ s: String, from now: Date = Date()) throws -> Date {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("for") {
            guard let secs = parseDuration(String(trimmed.dropFirst(3))), secs > 0 else {
                throw TimeError(message: "bad duration after 'for' — use e.g. \"for 90m\", \"for 2h\", \"for 1h30m\"")
            }
            return now.addingTimeInterval(secs)
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
            // Fail CLOSED: if the calendar can't resolve the day/time, error (no snooze written)
            // rather than silently standing enforcement down for a fallback minute.
            guard let d = nextTimeOfDay(hhmm: v, weekday: weekday, from: now) else {
                throw TimeError(message: "couldn't resolve \"until\" to a calendar date — try a plain \"until HHMM\"")
            }
            return d
        }
        throw TimeError(message: "expected \"for <duration>\" or \"until <[day]HHMM>\" — e.g. \"for 45m\" or \"until 0730\"")
    }

}
