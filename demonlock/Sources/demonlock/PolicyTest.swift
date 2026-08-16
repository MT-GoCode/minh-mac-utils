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

    // H3: deleting a referenced zone must NOT loosen. A dangling zone name evaluates to .unknown
    // (indeterminate), so NOT LOCATED_IN_ANY([deleted]) = NOT(unknown) = unknown = fail-closed,
    // never an allow-everywhere. Existing-zone semantics (inside→allow, outside→block) are unchanged.
    do {
        let notCasino = try PolicyEngine.parse("NOT LOCATED_IN_ANY([\"casino\"])")   // casino not in `zones`
        let r = PolicyEngine.evaluate(notCasino, PolicyInputs(now: Date(), fix: (34.0, -118.0), bssids: nil, zones: zones)).0
        check("dangling zone under NOT → unknown (not allow)", r == .unknown)
        let bare = try PolicyEngine.parse("LOCATED_IN_ANY([\"casino\"])")
        check("dangling zone bare → unknown",
              PolicyEngine.evaluate(bare, PolicyInputs(now: Date(), fix: (34.0, -118.0), bssids: nil, zones: zones)).0 == .unknown)
        let mixed = try PolicyEngine.parse("LOCATED_IN_ANY([\"office\", \"casino\"])")
        check("dangling mixed, inside a live zone → allow (match wins)",
              PolicyEngine.evaluate(mixed, PolicyInputs(now: Date(), fix: (34.0, -118.0), bssids: nil, zones: zones)).0 == .t)
        check("dangling mixed, outside the live zone → unknown",
              PolicyEngine.evaluate(mixed, PolicyInputs(now: Date(), fix: (0.0, 0.0), bssids: nil, zones: zones)).0 == .unknown)
        let office = try PolicyEngine.parse("LOCATED_IN_ANY([\"office\"])")
        check("existing zone inside → allow",
              PolicyEngine.evaluate(office, PolicyInputs(now: Date(), fix: (34.0, -118.0), bssids: nil, zones: zones)).0 == .t)
        check("existing zone outside → block",
              PolicyEngine.evaluate(office, PolicyInputs(now: Date(), fix: (0.0, 0.0), bssids: nil, zones: zones)).0 == .f)
    } catch { check("dangling-zone test parse: \(error)", false) }

    // AND short-circuits to false on a definitively-false clause even with unknown location.
    do {
        let p = try PolicyEngine.parse("LOCATED_IN_ANY([\"office\"]) AND TIME_IS_ANY([M0000-0001])")
        // If right now is not Monday 00:00–00:01, time is false ⇒ whole AND is false (not unknown).
        let r = PolicyEngine.evaluate(p, PolicyInputs(now: Date(), fix: nil, bssids: nil, zones: zones)).0
        let cal = Calendar.current
        let isMonMidnight = cal.component(.weekday, from: Date()) == 2 && cal.component(.hour, from: Date()) == 0 && cal.component(.minute, from: Date()) == 0
        check("false time clause forces block despite unknown loc", isMonMidnight ? true : r == .f)
    } catch { check("parse AND policy: \(error)", false) }

    // IN_POLICY (release-valve window primitive) — passes through the main verdict.
    do {
        let ip = try PolicyEngine.parse("IN_POLICY")
        func eval(_ tri: Tri) -> Tri {
            PolicyEngine.evaluate(ip, PolicyInputs(now: Date(), fix: nil, bssids: nil, zones: zones, inPolicy: tri)).0
        }
        check("IN_POLICY passes through .t",       eval(.t) == .t)
        check("IN_POLICY passes through .f",       eval(.f) == .f)
        check("IN_POLICY passes through .unknown", eval(.unknown) == .unknown)
        let wp = try PolicyEngine.parse("IN_POLICY AND TIME_IS_ANY([*0000-2400])")
        func w(_ tri: Tri) -> Tri {
            PolicyEngine.evaluate(wp, PolicyInputs(now: Date(), fix: nil, bssids: nil, zones: zones, inPolicy: tri)).0
        }
        check("window IN_POLICY(.t) AND all-day → allow", w(.t) == .t)
        check("window IN_POLICY(.f) AND all-day → block", w(.f) == .f)
    } catch { check("parse IN_POLICY: \(error)", false) }
    do { _ = try PolicyEngine.validate("IN_POLICY", zones: zones); check("IN_POLICY rejected in main policy", false) }
    catch { check("IN_POLICY rejected in main policy", true) }
    do { _ = try PolicyEngine.validate("IN_POLICY", zones: zones, allowInPolicy: true); check("IN_POLICY allowed in window policy", true) }
    catch { check("IN_POLICY allowed in window policy: \(error)", false) }

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

    // Location state machine (judgeLocation) — the security-critical core. confirmedUntil model: a new
    // fix OR an anchor overlap CONFIRMS (pushes confirmedUntil = now + grace); no confirmation → coast →
    // the fix goes STALE (not live) → fail-closed. The caller derives the usable fix from held.live(now).
    let st = Settings(graceSeconds: 90, maxAccuracyMeters: 150)      // push = now + 90
    func okFix(_ ts: Double, _ lat: Double = 34.0, _ lon: Double = -118.0, acc: Double = 30) -> FeedPayload {
        FeedPayload(ts: 0, lat: lat, lon: lon, acc: acc, fixTs: ts, bssids: nil, locState: "ok", scanTs: nil, guiPids: [])
    }
    let homeAPs: Set<String> = ["aa:00", "aa:01"]      // stable: 0x02 bit clear in first octet
    let awayAPs: Set<String> = ["bb:00", "bb:01"]

    // adopt: fresh fix + scan → held, confirmed, LIVE; confirmedUntil = 100 + 90 = 190
    let j1 = judgeLocation(held: nil, payload: okFix(100), stable: homeAPs, settings: st, now: 100)
    check("adopt: fresh fix → held + confirmed + live", j1.held != nil && j1.adopted && j1.confirmed && j1.persist && (j1.held?.live(now: 100) ?? false))
    check("adopt: confirmedUntil = now + grace",        j1.held?.confirmedUntil == 190)

    // stationary: no new fix, anchor still overlaps → re-confirmed, timer pushed to 150 + 90 = 240
    let j2 = judgeLocation(held: j1.held, payload: okFix(100), stable: homeAPs, settings: st, now: 150)
    check("stationary: overlap → confirmed, timer pushed", j2.confirmed && j2.held?.confirmedUntil == 240)

    // leave: anchor gone (no overlap), no new fix → NOT confirmed → coast (timer unchanged at 190)
    let j3 = judgeLocation(held: j1.held, payload: okFix(100), stable: awayAPs, settings: st, now: 150)
    check("leave: no overlap → not confirmed, coasting",  !j3.confirmed && j3.held?.confirmedUntil == 190 && (j3.held?.live(now: 150) ?? false))
    // coast then expire: still no overlap, now past confirmedUntil(190) → not live → fail-closed
    let j4 = judgeLocation(held: j3.held, payload: okFix(100), stable: awayAPs, settings: st, now: 200)
    check("coast expired → not live (fail-closed)",       !(j4.held?.live(now: 200) ?? true))

    // resurrection: same fixTs re-streamed after expiry → NOT adopted, NOT confirmed → stays not live
    let j5 = judgeLocation(held: j4.held, payload: okFix(100), stable: awayAPs, settings: st, now: 201)
    check("killed fix must NOT resurrect (same fixTs)",   !j5.adopted && !(j5.held?.live(now: 201) ?? true))

    // recovery: a genuinely newer fix re-adopts → confirmed, live again
    let j6 = judgeLocation(held: j4.held, payload: okFix(300, 0, 0), stable: awayAPs, settings: st, now: 300)
    check("newer fix revives location",                   j6.adopted && j6.held?.fixTs == 300 && (j6.held?.live(now: 300) ?? false))

    // no scan at adoption → empty anchor, but the fix itself confirms (live for grace), and the empty
    // anchor is NEVER grown/backfilled from a later scan (an offline move would otherwise pin old coords).
    let j7 = judgeLocation(held: nil, payload: okFix(100), stable: nil, settings: st, now: 100)
    check("no scan at adoption → adopt + live (empty anchor)", j7.adopted && j7.held?.anchor.isEmpty == true && (j7.held?.live(now: 100) ?? false))
    let j8 = judgeLocation(held: j7.held, payload: okFix(100), stable: awayAPs, settings: st, now: 150)
    check("empty anchor NOT backfilled",                  j8.held?.anchor.isEmpty == true && !j8.confirmed)

    // (agent-dead is handled in the TICK: no fresh feed → judgeLocation isn't called → confirmedUntil
    //  coasts → expires, identical to the j3/j4 coast-then-expire path above.)

    // BAND-STEERING: a full sweep returns BOTH radios at once, so the anchor holds both; the live scan
    // showing either band overlaps → confirmed. (Rich anchor + ≥1 overlap; no false lockout at home.)
    let fa = "f8:cf:c5:fe:16:fa", f9 = "f8:cf:c5:fe:16:f9"
    let s1 = judgeLocation(held: nil, payload: okFix(100), stable: [fa, f9], settings: st, now: 100)
    check("band-steer: anchor caught both bands",         s1.held?.anchor.count == 2)
    let s2 = judgeLocation(held: s1.held, payload: okFix(100), stable: [f9], settings: st, now: 1000)
    check("band-steer: one band still overlaps → confirmed", s2.confirmed && (s2.held?.live(now: 1000) ?? false))

    // too-fuzzy / invalid fixes are not adopted
    check("too-fuzzy fix not adopted",   judgeLocation(held: nil, payload: okFix(100, acc: 999), stable: homeAPs, settings: st, now: 100).held == nil)
    check("invalid (neg acc) not adopted", judgeLocation(held: nil, payload: okFix(100, acc: -1), stable: homeAPs, settings: st, now: 100).held == nil)

    print("\n\(pass) passed, \(fail) failed")
    exit(fail == 0 ? 0 : 1)
}
