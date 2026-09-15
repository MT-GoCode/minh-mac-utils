import XCTest
@testable import MacUtilsCore

final class TimeSpecTests: XCTestCase {
    // Pinned tz so DST / weekday math is deterministic regardless of the host.
    let la: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!; return c }()
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        la.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: 0))!
    }

    func testParseDuration() {
        XCTAssertEqual(TimeSpec.parseDuration("7h 3s"), 25203)
        XCTAssertEqual(TimeSpec.parseDuration("90m"), 5400)
        XCTAssertEqual(TimeSpec.parseDuration("1h30m"), 5400)
        XCTAssertEqual(TimeSpec.parseDuration("2d"), 172800)
        XCTAssertNil(TimeSpec.parseDuration("7"))       // trailing bare number
        XCTAssertNil(TimeSpec.parseDuration("h"))       // unit without number
        XCTAssertNil(TimeSpec.parseDuration("7x"))
        XCTAssertNil(TimeSpec.parseDuration(""))
    }

    func testWeekdayLettersAndValidHHMM() {
        XCTAssertEqual(TimeSpec.weekday("U"), 1); XCTAssertEqual(TimeSpec.weekday("m"), 2)
        XCTAssertEqual(TimeSpec.weekday("R"), 5); XCTAssertNil(TimeSpec.weekday("X"))
        XCTAssertEqual(TimeSpec.letters(for: [2, 4, 6]), "MWF")
        XCTAssertEqual(TimeSpec.letters(for: [1, 2, 3, 4, 5, 6, 7]), "*")
        XCTAssertTrue(TimeSpec.validHHMM(2359)); XCTAssertFalse(TimeSpec.validHHMM(2400)); XCTAssertFalse(TimeSpec.validHHMM(860))
    }

    func testNextTimeOfDay() {
        let now = date(2026, 6, 24, 8, 10)   // Wed
        XCTAssertEqual(TimeSpec.nextTimeOfDay(hhmm: 900, weekday: nil, from: now, calendar: la), date(2026, 6, 24, 9, 0))   // later today
        XCTAssertEqual(TimeSpec.nextTimeOfDay(hhmm: 800, weekday: nil, from: now, calendar: la), date(2026, 6, 25, 8, 0))   // passed → tomorrow
        XCTAssertEqual(TimeSpec.nextTimeOfDay(hhmm: 810, weekday: nil, from: now, calendar: la), date(2026, 6, 25, 8, 10))  // strictly future
        let sun = TimeSpec.nextTimeOfDay(hhmm: 800, weekday: 1, from: now, calendar: la)!
        XCTAssertEqual(la.component(.weekday, from: sun), 1); XCTAssertEqual(sun, date(2026, 6, 28, 8, 0))
        // same weekday, time already passed today → 7 days out (the 8-day search window covers it)
        XCTAssertEqual(TimeSpec.nextTimeOfDay(hhmm: 700, weekday: 4, from: now, calendar: la), date(2026, 7, 1, 7, 0))
    }

    func testNextTimeOfDayAcrossSpringForward() {
        // 2026-03-08 02:00 PST → 03:00 PDT in LA. Asking for 02:30 that night resolves via the
        // calendar (Foundation shifts the nonexistent time forward); the point is: no crash, strictly
        // future, and the following day's 02:30 exists.
        let now = date(2026, 3, 7, 23, 0)
        let t = TimeSpec.nextTimeOfDay(hhmm: 230, weekday: nil, from: now, calendar: la)
        XCTAssertNotNil(t); XCTAssertGreaterThan(t!, now)
    }

    func testFmt() {
        XCTAssertEqual(TimeSpec.fmtLeft(5400), "1h30m")
        XCTAssertEqual(TimeSpec.fmtLeft(310), "5m10s")
        XCTAssertEqual(TimeSpec.fmtLeft(40), "40s")
        XCTAssertEqual(TimeSpec.fmtLeft(-5), "0s")
        XCTAssertFalse(TimeSpec.fmtWhen(0, "yyyy").isEmpty)
    }
}
