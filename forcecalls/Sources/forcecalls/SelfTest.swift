import Foundation

/// `forcecalls selftest` — asserts the schedule math, which is the only part of this tool with
/// logic worth getting wrong. Everything else is file plumbing that fails loudly on its own.
///
/// The occurrence tests build fixed local dates, so they exercise the same current-timezone
/// resolution the daemon uses at 8:45 PM.
enum SelfTest {

    static func run() {
        var failures = 0
        func check(_ label: String, _ cond: Bool) {
            print("  \(cond ? "✓" : "✗") \(label)")
            if !cond { failures += 1 }
        }

        // MARK: parsing
        let every = try? ScheduleSpec.parse("*2045")
        check("*2045 → every day, 20:45", every?.days == Set(1...7) && every?.hhmm == 2045)

        let mwf = try? ScheduleSpec.parse("mwf0700")
        check("mwf0700 → Mon/Wed/Fri 07:00 (case-insensitive)", mwf?.days == Set([1, 3, 5]) && mwf?.hhmm == 700)

        let sun = try? ScheduleSpec.parse("U1000")
        check("U1000 → Sunday only", sun?.days == Set([7]) && sun?.hhmm == 1000)

        check("R is Thursday, not Friday", (try? ScheduleSpec.parse("R0900"))?.days == Set([4]))
        check("raw is preserved uppercased", (try? ScheduleSpec.parse("mwf0700"))?.raw == "MWF0700")

        for bad in ["XX99", "2045", "*", "*999", "*2460", "*2065", "M240000", "", "*20:45"] {
            check("rejects '\(bad)'", (try? ScheduleSpec.parse(bad)) == nil)
        }

        // MARK: bare HHMM, allowed only for one-shots
        check("bare 2045 is rejected by default", (try? ScheduleSpec.parse("2045")) == nil)
        let bare = try? ScheduleSpec.parse("2045", allowBareTime: true)
        check("bare 2045 with allowBareTime → every day 20:45", bare?.days == Set(1...7) && bare?.hhmm == 2045)
        check("allowBareTime doesn't loosen anything else",
              (try? ScheduleSpec.parse("99", allowBareTime: true)) == nil
              && (try? ScheduleSpec.parse("2460", allowBareTime: true)) == nil
              && (try? ScheduleSpec.parse("XX99", allowBareTime: true)) == nil)
        check("day letters still work with allowBareTime",
              (try? ScheduleSpec.parse("MWF0700", allowBareTime: true))?.days == Set([1, 3, 5]))

        // MARK: flag defaults survive a round-trip through calls.json
        let plain = """
            {"id":1,"name":"mom","destination":"+15559998888",
             "schedule":{"days":[1,2,3,4,5,6,7],"hhmm":2045,"raw":"*2045"}}
            """
        let decoded = try? JSONDecoder().decode(ForcedCall.self, from: Data(plain.utf8))
        check("a calls.json entry with no flags decodes with both off",
              decoded != nil && decoded?.once == false && decoded?.hangupOnMachine == false)

        // MARK: occurrence math
        // Wednesday 2026-08-19, local.
        func at(_ day: Int, _ h: Int, _ m: Int) -> Date {
            var c = DateComponents()
            c.year = 2026; c.month = 8; c.day = day; c.hour = h; c.minute = m; c.second = 0
            return Calendar.current.date(from: c)!
        }
        let wedWeekday = Calendar.current.component(.weekday, from: at(19, 12, 0))
        check("2026-08-19 really is a Wednesday", wedWeekday == 4)

        let daily = try! ScheduleSpec.parse("*2045")
        check("daily, at 21:00 → most recent is today 20:45",
              daily.mostRecentOccurrence(now: at(19, 21, 0)) == at(19, 20, 45).timeIntervalSince1970)
        check("daily, at 20:00 → most recent is YESTERDAY 20:45",
              daily.mostRecentOccurrence(now: at(19, 20, 0)) == at(18, 20, 45).timeIntervalSince1970)
        check("daily, at 20:00 → next is today 20:45",
              daily.nextOccurrence(now: at(19, 20, 0)) == at(19, 20, 45).timeIntervalSince1970)
        check("daily, exactly at 20:45 counts as due (boundary is inclusive)",
              daily.mostRecentOccurrence(now: at(19, 20, 45)) == at(19, 20, 45).timeIntervalSince1970)

        let sparse = try! ScheduleSpec.parse("MWF0700")
        check("MWF, Wed 06:00 → most recent is MONDAY 07:00 (skips back past Tue)",
              sparse.mostRecentOccurrence(now: at(19, 6, 0)) == at(17, 7, 0).timeIntervalSince1970)
        check("MWF, Wed 06:00 → next is today 07:00",
              sparse.nextOccurrence(now: at(19, 6, 0)) == at(19, 7, 0).timeIntervalSince1970)
        check("MWF, Wed 08:00 → next is FRIDAY 07:00",
              sparse.nextOccurrence(now: at(19, 8, 0)) == at(21, 7, 0).timeIntervalSince1970)

        let sundays = try! ScheduleSpec.parse("U1000")
        check("Sundays, Wed → next is Sunday the 23rd",
              sundays.nextOccurrence(now: at(19, 12, 0)) == at(23, 10, 0).timeIntervalSince1970)

        // The grace window is what decides "due"; a stale occurrence must not fire on daemon restart.
        let staleAge = at(19, 21, 0).timeIntervalSince1970 - daily.mostRecentOccurrence(now: at(19, 21, 0))!
        check("an occurrence 15min old is outside the 120s grace window", staleAge > 120)

        // MARK: destinations
        check("accepts +15559998888", (try? validateDestination("+15559998888")) == "+15559998888")
        check("strips spaces", (try? validateDestination("+1 555 999 8888")) == "+15559998888")
        for bad in ["5551112222", "+", "+abc1234567", "", "15559998888"] {
            check("rejects destination '\(bad)'", (try? validateDestination(bad)) == nil)
        }

        print(failures == 0 ? "\nall checks passed" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
