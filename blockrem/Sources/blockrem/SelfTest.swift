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

    // --- Alarm.activeEnd (durations now in SECONDS) ---
    let wed0810 = date(2026, 6, 24, 8, 10)
    let aWeekly = Alarm(id: 1, label: "x", durationSec: 1800, kind: .weekly(days: [4], hhmm: 800))   // Wed 08:00, 30m
    check("weekly active at 08:10", aWeekly.activeEnd(now: wed0810) == date(2026, 6, 24, 8, 30).timeIntervalSince1970)
    check("weekly inactive at 08:40", aWeekly.activeEnd(now: date(2026, 6, 24, 8, 40)) == nil)
    check("weekly wrong day", Alarm(id: 1, label: "x", durationSec: 1800, kind: .weekly(days: [3], hhmm: 800))
            .activeEnd(now: wed0810) == nil)

    // midnight cross: Tue 23:50 + 1800s → Wed 00:20; check at Wed 00:10
    let crosser = Alarm(id: 2, label: "x", durationSec: 1800, kind: .weekly(days: [3], hhmm: 2350))  // Tue
    check("weekly crosses midnight", crosser.activeEnd(now: date(2026, 6, 24, 0, 10)) != nil)

    // onetime active + expiry
    let start = date(2026, 6, 24, 8, 0).timeIntervalSince1970
    let aOnce = Alarm(id: 3, label: "x", durationSec: 1200, kind: .onetime(start: start))
    check("onetime active mid", aOnce.activeEnd(now: date(2026, 6, 24, 8, 10)) == start + 1200)
    check("onetime inactive after", aOnce.activeEnd(now: date(2026, 6, 24, 8, 30)) == nil)
    check("onetime expired prunes", aOnce.isExpiredOnetime(now: date(2026, 6, 24, 8, 30)))
    check("onetime not expired during", !aOnce.isExpiredOnetime(now: date(2026, 6, 24, 8, 10)))

    // activeBlock picks the latest-ending overlap
    let a = Alarm(id: 1, label: "short", durationSec: 600, kind: .onetime(start: start))
    let b = Alarm(id: 2, label: "long", durationSec: 2400, kind: .onetime(start: start))
    let winner = activeBlock([a, b], now: date(2026, 6, 24, 8, 5))
    check("activeBlock latest end wins", winner?.label == "long")

    // --- alarmsOverlap ---
    let s8 = date(2026, 6, 24, 8, 0).timeIntervalSince1970
    let o1 = Alarm(id: 1, label: "o1", durationSec: 600, kind: .onetime(start: s8))               // 08:00–08:10
    let o2 = Alarm(id: 2, label: "o2", durationSec: 600, kind: .onetime(start: s8 + 300))          // 08:05–08:15
    let o3 = Alarm(id: 3, label: "o3", durationSec: 600, kind: .onetime(start: s8 + 1200))         // 08:20–08:30
    check("onetime×onetime overlap", alarmsOverlap(o1, o2))
    check("onetime×onetime disjoint", !alarmsOverlap(o1, o3))

    let w1 = Alarm(id: 4, label: "w1", durationSec: 1800, kind: .weekly(days: [2, 4], hhmm: 800))   // Mon/Wed 08:00, 30m
    let w2 = Alarm(id: 5, label: "w2", durationSec: 1800, kind: .weekly(days: [4], hhmm: 815))      // Wed 08:15, 30m (overlaps w1 Wed)
    let w3 = Alarm(id: 6, label: "w3", durationSec: 1800, kind: .weekly(days: [6], hhmm: 800))      // Fri 08:00 (different day)
    check("weekly×weekly same-day overlap", alarmsOverlap(w1, w2))
    check("weekly×weekly different-day", !alarmsOverlap(w1, w3))

    // weekly Wed 08:00–08:30 vs a onetime at Wed 08:10 → overlap
    check("weekly×onetime overlap", alarmsOverlap(w1, Alarm(id: 7, label: "o", durationSec: 300,
            kind: .onetime(start: date(2026, 6, 24, 8, 10).timeIntervalSince1970))))
    check("weekly×onetime miss", !alarmsOverlap(w1, Alarm(id: 8, label: "o", durationSec: 300,
            kind: .onetime(start: date(2026, 6, 24, 9, 0).timeIntervalSince1970))))

    // --- parseFirstOn ---
    check("fo *0500-0900", TimeSpec.parseFirstOn("*0500-0900").map { $0.days.count == 7 && $0.start == 500 && $0.end == 900 } ?? false)
    check("fo MWF0700-1000", TimeSpec.parseFirstOn("MWF0700-1000").map { $0.days == [2,4,6] && $0.start == 700 && $0.end == 1000 } ?? false)
    check("fo reversed", TimeSpec.parseFirstOn("*0900-0500") == nil)
    check("fo equal", TimeSpec.parseFirstOn("*0500-0500") == nil)
    check("fo no dash", TimeSpec.parseFirstOn("*05000900") == nil)
    check("fo bad day", TimeSpec.parseFirstOn("X0500-0900") == nil)
    check("fo bad hhmm", TimeSpec.parseFirstOn("*2430-2500") == nil)

    // --- sessionInUse (pure freshness ∧ !locked ∧ !displayAsleep) ---
    let t0 = 1_000_000.0
    func sess(_ age: Double, _ locked: Bool, _ asleep: Bool) -> SessionState {
        SessionState(updatedEpoch: t0 - age, locked: locked, displayAsleep: asleep)
    }
    check("inUse fresh unlocked", sessionInUse(sess(10, false, false), now: t0))
    check("inUse stale", !sessionInUse(sess(120, false, false), now: t0))
    check("inUse missing", !sessionInUse(nil, now: t0))
    check("inUse locked", !sessionInUse(sess(10, true, false), now: t0))
    check("inUse display asleep", !sessionInUse(sess(10, false, true), now: t0))

    // --- firstOnShouldFire (Wed 2026-06-24; window *0500-0900, 300s) ---
    func fo(_ fired: Double? = nil, days: [Int] = [1,2,3,4,5,6,7]) -> Alarm {
        var a = Alarm(id: 9, label: "fo", durationSec: 300, kind: .firstOn(days: days, startHHMM: 500, endHHMM: 900))
        a.lastFiredEpoch = fired
        return a
    }
    let wed0500 = date(2026, 6, 24, 5, 0)
    check("fo fires at window start", firstOnShouldFire(fo(), now: wed0500, inUse: true, snoozedUntil: nil))
    check("fo fires mid-window", firstOnShouldFire(fo(), now: date(2026, 6, 24, 7, 23), inUse: true, snoozedUntil: nil))
    check("fo not before window", !firstOnShouldFire(fo(), now: date(2026, 6, 24, 4, 59), inUse: true, snoozedUntil: nil))
    check("fo not at window end", !firstOnShouldFire(fo(), now: date(2026, 6, 24, 9, 0), inUse: true, snoozedUntil: nil))
    check("fo not when not in use", !firstOnShouldFire(fo(), now: wed0500, inUse: false, snoozedUntil: nil))
    check("fo wrong day", !firstOnShouldFire(fo(days: [2]), now: wed0500, inUse: true, snoozedUntil: nil))
    let fired0700 = date(2026, 6, 24, 7, 0).timeIntervalSince1970
    check("fo no refire same day", !firstOnShouldFire(fo(fired0700), now: date(2026, 6, 24, 8, 0), inUse: true, snoozedUntil: nil))
    let firedYesterday = date(2026, 6, 23, 7, 0).timeIntervalSince1970
    check("fo next day resets", firstOnShouldFire(fo(firedYesterday), now: wed0500, inUse: true, snoozedUntil: nil))
    let snUntil = date(2026, 6, 24, 7, 0).timeIntervalSince1970
    check("fo snoozed no fire", !firstOnShouldFire(fo(), now: date(2026, 6, 24, 6, 0), inUse: true, snoozedUntil: snUntil))
    check("fo fires when snooze clears", firstOnShouldFire(fo(), now: date(2026, 6, 24, 7, 0), inUse: true, snoozedUntil: snUntil))
    // --- mergeFirstOnLatches (memory-authoritative, two-way) ---
    // failed save / CLI clobber: memory latched, disk nil → latch restored + re-persist flagged
    let mClobber = mergeFirstOnLatches(fired: [9: fired0700], alarms: [fo(nil)])
    check("merge restores clobbered latch", mClobber.alarms[0].lastFiredEpoch == fired0700 && mClobber.mutated
          && mClobber.fired[9] == fired0700)
    check("merge blocks refire after clobber", !firstOnShouldFire(mClobber.alarms[0],
          now: date(2026, 6, 24, 7, 30), inUse: true, snoozedUntil: nil))
    // daemon restart: memory empty, disk latched → fired map reseeded, no double-fire
    let mRestart = mergeFirstOnLatches(fired: [:], alarms: [fo(fired0700)])
    check("merge reseeds after restart", mRestart.fired[9] == fired0700 && !mRestart.mutated)
    check("merge blocks refire after restart", !firstOnShouldFire(mRestart.alarms[0],
          now: date(2026, 6, 24, 8, 0), inUse: true, snoozedUntil: nil))
    // newer memory wins over older disk; deleted id dropped
    let older = fired0700 - 3600
    let mNewer = mergeFirstOnLatches(fired: [9: fired0700, 99: fired0700], alarms: [fo(older)])
    check("merge newer memory wins", mNewer.alarms[0].lastFiredEpoch == fired0700 && mNewer.mutated)
    check("merge drops deleted ids", mNewer.fired[99] == nil)

    // --- activeEnd for firstOn (block resume after daemon restart = latch persisted) ---
    check("fo block active mid", fo(fired0700).activeEnd(now: date(2026, 6, 24, 7, 2)) == fired0700 + 300)
    check("fo block over", fo(fired0700).activeEnd(now: date(2026, 6, 24, 7, 6)) == nil)
    check("fo unfired inactive", fo().activeEnd(now: date(2026, 6, 24, 7, 2)) == nil)

    // --- overlap: firstOn *0500-0900 dur 300 occupies [05:00, 09:05) each day ---
    let foAll = fo()
    func wk(_ hhmm: Int, dur: Int = 30) -> Alarm {
        Alarm(id: 10, label: "w", durationSec: dur, kind: .weekly(days: [1,2,3,4,5,6,7], hhmm: hhmm))
    }
    check("fo×wk 0830 clash", alarmsOverlap(foAll, wk(830)))
    check("fo×wk 0904 clash", alarmsOverlap(foAll, wk(904)))
    check("fo×wk 0906 ok", !alarmsOverlap(foAll, wk(906)))
    check("fo×wk 0910 ok", !alarmsOverlap(foAll, wk(910)))
    check("fo×wk 0456 dur300 clash", alarmsOverlap(foAll, wk(456, dur: 300)))
    check("fo×wk 0454 dur300 ok", !alarmsOverlap(foAll, wk(454, dur: 300)))
    check("fo×once inside", alarmsOverlap(foAll, Alarm(id: 11, label: "o", durationSec: 60,
            kind: .onetime(start: date(2026, 6, 24, 8, 0).timeIntervalSince1970))))
    check("fo×once outside", !alarmsOverlap(foAll, Alarm(id: 12, label: "o", durationSec: 60,
            kind: .onetime(start: date(2026, 6, 24, 10, 0).timeIntervalSince1970))))
    let foLate = Alarm(id: 13, label: "fo2", durationSec: 300, kind: .firstOn(days: [1,2,3,4,5,6,7], startHHMM: 900, endHHMM: 1100))
    let foLater = Alarm(id: 14, label: "fo3", durationSec: 300, kind: .firstOn(days: [1,2,3,4,5,6,7], startHHMM: 910, endHHMM: 1100))
    check("fo×fo overlapping", alarmsOverlap(foAll, foLate))       // [05:00,09:05) ∩ [09:00,…)
    check("fo×fo disjoint", !alarmsOverlap(foAll, foLater))        // [09:10,…) misses 09:05

    // --- Codable migration ---
    let oldJSON = """
    [{"id":1,"label":"legacy","durationSec":30,"kind":{"weekly":{"days":[4],"hhmm":800}}}]
    """.data(using: .utf8)!
    let decodedOld = try? JSONDecoder().decode([Alarm].self, from: oldJSON)
    check("old schedule decodes", decodedOld?.count == 1 && decodedOld?[0].lastFiredEpoch == nil)
    let enc = JSONEncoder()
    if let data = try? enc.encode([fo(fired0700)]),
       let back = try? JSONDecoder().decode([Alarm].self, from: data) {
        check("firstOn round-trips with latch", back[0].lastFiredEpoch == fired0700
              && { if case .firstOn(_, 500, 900) = back[0].kind { return true }; return false }())
    } else { check("firstOn round-trips with latch", false) }

    print("\n\(pass) passed, \(fail) failed")
    exit(fail == 0 ? 0 : 1)
}
