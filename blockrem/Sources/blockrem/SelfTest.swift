import Foundation

/// Pure-logic regression tests for the time parsing + active-window math (the root-gated paths the
/// CLI can't exercise without sudo). Run: `blockrem _selftest`. Exits nonzero on any failure.
func runSelfTest() {
    var pass = 0, fail = 0
    func check(_ name: String, _ cond: Bool) {
        if cond { pass += 1; print("PASS  \(name)") }
        else { fail += 1; print("FAIL  \(name)") }
    }
    let cal = Calendar.current
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: 0))!
    }

    // --- parseDuration ---
    check("dur 7h 3s",   TimeSpec.parseDuration("7h 3s") == 25203)
    check("dur 30m",     TimeSpec.parseDuration("30m") == 1800)
    check("dur 1h30m",   TimeSpec.parseDuration("1h30m") == 5400)
    check("dur 2d",      TimeSpec.parseDuration("2d") == 172800)
    check("dur bare num",TimeSpec.parseDuration("7") == nil)
    check("dur junk",    TimeSpec.parseDuration("7x") == nil)
    check("dur empty",   TimeSpec.parseDuration("") == nil)
    check("dur unit only",TimeSpec.parseDuration("h") == nil)

    // --- parseWeekly ---
    check("wk *0800",  TimeSpec.parseWeekly("*0800").map { $0.days == [1,2,3,4,5,6,7] && $0.hhmm == 800 } ?? false)
    check("wk R0800",  TimeSpec.parseWeekly("R0800").map { $0.days == [5] && $0.hhmm == 800 } ?? false)
    check("wk MWF0730",TimeSpec.parseWeekly("MWF0730").map { $0.days == [2,4,6] && $0.hhmm == 730 } ?? false)
    check("wk too short", TimeSpec.parseWeekly("0800") == nil)
    check("wk bad day",   TimeSpec.parseWeekly("X0800") == nil)
    check("wk bad hhmm",  TimeSpec.parseWeekly("R0860") == nil)
    check("wk hhmm 2400", TimeSpec.parseWeekly("R2400") == nil)

    // --- parseWhen (deterministic with injected now) ---
    let now = date(2026, 6, 24, 8, 10)   // Wed
    if case .success(let t) = TimeSpec.parseWhen("for 90m", now: now) {
        check("when for 90m", abs(t.timeIntervalSince(now) - 5400) < 1)
    } else { check("when for 90m", false) }
    if case .success(let t) = TimeSpec.parseWhen("at 0900", now: now) {
        check("when at 0900 today", t == date(2026, 6, 24, 9, 0))
    } else { check("when at 0900 today", false) }
    if case .success(let t) = TimeSpec.parseWhen("at 0800", now: now) {
        check("when at 0800 → tomorrow", t == date(2026, 6, 25, 8, 0))   // 08:00 already passed today
    } else { check("when at 0800 → tomorrow", false) }
    if case .success(let t) = TimeSpec.parseWhen("at U0800", now: now) {
        check("when at U0800 is Sunday", cal.component(.weekday, from: t) == 1 && t > now)
    } else { check("when at U0800", false) }
    check("when bogus fails", { if case .failure = TimeSpec.parseWhen("nonsense", now: now) { return true }; return false }())

    // --- Alarm.activeEnd ---
    let wed0810 = date(2026, 6, 24, 8, 10)
    let aWeekly = Alarm(id: 1, label: "x", durationMin: 30, kind: .weekly(days: [4], hhmm: 800))   // Wed 08:00
    check("weekly active at 08:10", aWeekly.activeEnd(now: wed0810) == date(2026, 6, 24, 8, 30).timeIntervalSince1970)
    check("weekly inactive at 08:40", aWeekly.activeEnd(now: date(2026, 6, 24, 8, 40)) == nil)
    check("weekly wrong day", Alarm(id: 1, label: "x", durationMin: 30, kind: .weekly(days: [3], hhmm: 800))
            .activeEnd(now: wed0810) == nil)

    // midnight cross: Tue 23:50 + 30m → Wed 00:20; check at Wed 00:10
    let crosser = Alarm(id: 2, label: "x", durationMin: 30, kind: .weekly(days: [3], hhmm: 2350))  // Tue
    check("weekly crosses midnight", crosser.activeEnd(now: date(2026, 6, 24, 0, 10)) != nil)

    // onetime active + expiry
    let start = date(2026, 6, 24, 8, 0).timeIntervalSince1970
    let aOnce = Alarm(id: 3, label: "x", durationMin: 20, kind: .onetime(start: start))
    check("onetime active mid", aOnce.activeEnd(now: date(2026, 6, 24, 8, 10)) == start + 1200)
    check("onetime inactive after", aOnce.activeEnd(now: date(2026, 6, 24, 8, 30)) == nil)
    check("onetime expired prunes", aOnce.isExpiredOnetime(now: date(2026, 6, 24, 8, 30)))
    check("onetime not expired during", !aOnce.isExpiredOnetime(now: date(2026, 6, 24, 8, 10)))

    // activeBlock picks the latest-ending overlap
    let a = Alarm(id: 1, label: "short", durationMin: 10, kind: .onetime(start: start))
    let b = Alarm(id: 2, label: "long", durationMin: 40, kind: .onetime(start: start))
    let winner = activeBlock([a, b], now: date(2026, 6, 24, 8, 5))
    check("activeBlock latest end wins", winner?.label == "long")

    print("\n\(pass) passed, \(fail) failed")
    exit(fail == 0 ? 0 : 1)
}
