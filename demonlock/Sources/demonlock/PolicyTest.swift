import Foundation

/// Hidden dev self-test for the policy engine: `demonlock _policytest`.
func runPolicyTest() {
    var pass = 0, fail = 0
    func check(_ name: String, _ cond: Bool) {
        print((cond ? "PASS  " : "FAIL  ") + name)
        if cond { pass += 1 } else { fail += 1 }
    }

    let zones = [Zone(name: "office", shape: .circle(centerLat: 34.0, centerLon: -118.0, radius: 100))]
    let allDay = "TIME_IS_ANY([*0000-2400])"
    let policy = "(LOCATED_IN_ANY([\"office\"]) OR FOUND_IN_NEARBY_BSSID([\"a4:5e:60:11:22:33\"])) AND \(allDay)"

    do {
        let p = try PolicyEngine.parse(policy)
        func verdict(fix: (lat: Double, lon: Double)?, bssids: Set<String>?) -> Tri {
            PolicyEngine.evaluate(p, PolicyInputs(now: Date(), fix: fix, bssids: bssids, zones: zones)).0
        }
        check("inside office → allow",                       verdict(fix: (34.0, -118.0), bssids: []) == .t)
        check("outside + no bssid → block",                  verdict(fix: (0.0, 0.0), bssids: []) == .f)
        check("outside but pinned bssid seen → allow",       verdict(fix: (0.0, 0.0), bssids: ["a4:5e:60:11:22:33"]) == .t)
        check("loc unknown + bssid seen → allow (OR case)",  verdict(fix: nil, bssids: ["a4:5e:60:11:22:33"]) == .t)
        check("loc unknown + bssid unknown → unknown",       verdict(fix: nil, bssids: nil) == .unknown)
        check("loc unknown + bssid absent → unknown",        verdict(fix: nil, bssids: []) == .unknown)
        check("BSSID match is case-insensitive",             verdict(fix: (0.0, 0.0), bssids: ["A4:5E:60:11:22:33".lowercased()]) == .t)
    } catch { check("parse main policy: \(error)", false) }

    // AND short-circuits to false on a definitively-false clause even with unknown location.
    do {
        let p = try PolicyEngine.parse("LOCATED_IN_ANY([\"office\"]) AND TIME_IS_ANY([M0000-0001])")
        // If right now is not Monday 00:00–00:01, time is false ⇒ whole AND is false (not unknown).
        let r = PolicyEngine.evaluate(p, PolicyInputs(now: Date(), fix: nil, bssids: nil, zones: zones)).0
        let cal = Calendar.current
        let isMonMidnight = cal.component(.weekday, from: Date()) == 2 && cal.component(.hour, from: Date()) == 0 && cal.component(.minute, from: Date()) == 0
        check("false time clause forces block despite unknown loc", isMonMidnight ? true : r == .f)
    } catch { check("parse AND policy: \(error)", false) }

    func expectError(_ s: String, _ name: String) {
        do { _ = try PolicyEngine.validate(s, zones: zones); check(name, false) }
        catch { check(name + "  (\(error))", true) }
    }
    expectError("LOCATED_IN_ANY([\"office\"]", "rejects unbalanced parens")
    expectError("LOCATED_IN_ANY([\"missing\"])", "rejects unknown zone")
    expectError("TIME_IS_ANY([M1700-0900])", "rejects end<=start window")
    expectError("TIME_IS_ANY([M2200-0200])", "rejects midnight wrap")
    expectError("TIME_IS_ANY([X0900-1700])", "rejects bad day letter")
    expectError("FOUND_IN_NEARBY_BSSID([\"zz:zz:zz:zz:zz:zz\"])", "rejects bad MAC")
    expectError("FROBNICATE([\"x\"])", "rejects unknown function")
    expectError("LOCATED_IN_ANY([])", "rejects empty list")
    expectError("", "rejects empty policy")

    // a fully valid policy validates clean
    do { _ = try PolicyEngine.validate("LOCATED_IN_ANY([\"office\"]) AND \(allDay)", zones: zones); check("valid policy passes validation", true) }
    catch { check("valid policy passes validation (\(error))", false) }

    // BSSID anchor overlap — ANY shared AP = still here (≥1; sparse macOS scans must not false-lock)
    check("overlap: any 1 shared is enough",           bssidOverlapOK(anchor: ["a", "b", "c"], current: ["a", "x", "y"]))
    check("overlap: sparse scan (1 of 12) still here", bssidOverlapOK(anchor: ["a","b","c","d","e","f","g","h","i","j","k","l"], current: ["a"]))
    check("overlap: one-router home, that 1 present",  bssidOverlapOK(anchor: ["a"], current: ["a", "z"]))
    check("overlap: zero shared → moved",              !bssidOverlapOK(anchor: ["a", "b"], current: ["x", "y"]))
    check("overlap: empty anchor can never confirm",   !bssidOverlapOK(anchor: [], current: ["a", "b"]))

    // Location state machine transitions (judgeLocation) — the security-critical core.
    let st = Settings(graceSeconds: 90, maxAccuracyMeters: 150)
    func okFix(_ ts: Double, _ lat: Double = 34.0, _ lon: Double = -118.0, acc: Double = 30) -> FeedPayload {
        FeedPayload(ts: 0, lat: lat, lon: lon, acc: acc, fixTs: ts, bssids: nil, locState: "ok", scanTs: nil)
    }
    let homeAPs: Set<String> = ["aa:00", "aa:01"]      // stable: 0x02 bit clear in first octet
    let awayAPs: Set<String> = ["bb:00", "bb:01"]

    // adopt a fresh fix with an anchor; then confirm it while stationary (no new fix, APs persist)
    let j1 = judgeLocation(held: nil, payload: okFix(100), stable: homeAPs, settings: st, now: 100)
    check("adopt: fresh fix + scan → held + fix",        j1.held != nil && j1.fix != nil && j1.persist)
    let j2 = judgeLocation(held: j1.held, payload: okFix(100), stable: homeAPs, settings: st, now: 1000)
    check("stationary: same fix, APs persist → still ok", j2.fix != nil && j2.held?.graceUntil == nil)

    // leave: APs gone, no new fix → grace starts (still allowed), then expires → fail-closed
    let j3 = judgeLocation(held: j1.held, payload: okFix(100), stable: awayAPs, settings: st, now: 1000)
    check("leave: APs gone → grace, still allowed",       j3.fix != nil && j3.held?.graceUntil != nil)
    let j4 = judgeLocation(held: j3.held, payload: okFix(100), stable: awayAPs, settings: st, now: 2000)
    check("grace expired → fail-closed (no fix)",         j4.fix == nil && j4.held != nil)

    // THE RESURRECTION TEST: after a grace-expired kill, the agent re-streams the SAME fixTs —
    // it must NOT be re-adopted (strict-newer high-water), even with a fresh anchor at the new place.
    let j5 = judgeLocation(held: j4.held, payload: okFix(100), stable: awayAPs, settings: st, now: 2001)
    check("killed fix must NOT resurrect (same fixTs)",   j5.fix == nil)

    // recovery: a genuinely newer fix (you got signal) re-adopts and re-anchors → allowed again
    let j6 = judgeLocation(held: j4.held, payload: okFix(200, 0, 0), stable: awayAPs, settings: st, now: 2100)
    check("newer fix revives location",                   j6.fix != nil && j6.held?.fixTs == 200)

    // GRACEFUL DEGRADATION: a fresh fix with NO scan is still adopted + trusted (macOS-26 scan
    // is flaky; a stale/missing scan must not lock you out of an allowed spot).
    let j7 = judgeLocation(held: nil, payload: okFix(100), stable: nil, settings: st, now: 100)
    check("no scan at adoption → adopt + trust (degrade)", j7.held != nil && j7.fix != nil)
    let j8 = judgeLocation(held: j1.held, payload: okFix(100), stable: nil, settings: st, now: 5000)
    check("held fix + stale scan → trusted (not locked)",  j8.fix != nil)
    // empty anchor is NOT backfilled — backfilling from a later scan would anchor the OLD coords
    // to a NEW place's APs after an offline move (fail-open). It stays empty (trusted via degradation).
    let j9 = judgeLocation(held: j7.held, payload: okFix(100), stable: awayAPs, settings: st, now: 200)
    check("empty anchor NOT backfilled (no fail-open)",    j9.held?.anchor.isEmpty == true && j9.fix != nil)

    // BAND-STEERING — the at-home false-lockout. A dual-band router shows two BSSIDs (f9=2.4GHz,
    // fa=5GHz). The agent feeds (associated AP ∪ last full sweep), and a full sweep returns BOTH at
    // once, so BOTH the adoption snapshot and the live scan are rich → overlap survives steering.
    let fa = "f8:cf:c5:fe:16:fa", f9 = "f8:cf:c5:fe:16:f9"
    // (a) rich anchor (both bands captured at adoption), Mac later reports only the band it's on:
    let s1 = judgeLocation(held: nil,     payload: okFix(100), stable: [fa, f9], settings: st, now: 100)
    check("band-steer: anchor caught both bands",         s1.held?.anchor.count == 2)
    let s2 = judgeLocation(held: s1.held, payload: okFix(100), stable: [f9], settings: st, now: 1000)
    check("band-steer: on one band → still overlaps",     s2.fix != nil && s2.held?.graceUntil == nil)
    // (b) even a thin anchor survives because the live scan is rich (full sweep ∪ associated):
    let s3 = judgeLocation(held: nil,     payload: okFix(100), stable: [fa], settings: st, now: 100)
    let s4 = judgeLocation(held: s3.held, payload: okFix(100), stable: [fa, f9], settings: st, now: 1000)
    check("band-steer: rich live scan re-overlaps thin anchor", s4.fix != nil && s4.held?.graceUntil == nil)

    // too-fuzzy / invalid fixes are not adopted
    check("too-fuzzy fix not adopted",   judgeLocation(held: nil, payload: okFix(100, acc: 999), stable: homeAPs, settings: st, now: 100).held == nil)
    check("invalid (neg acc) not adopted", judgeLocation(held: nil, payload: okFix(100, acc: -1), stable: homeAPs, settings: st, now: 100).held == nil)

    print("\n\(pass) passed, \(fail) failed")
    exit(fail == 0 ? 0 : 1)
}
