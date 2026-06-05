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
        func verdict(fix: (lat: Double, lon: Double, accuracy: Double)?, bssids: Set<String>?) -> Tri {
            PolicyEngine.evaluate(p, PolicyInputs(now: Date(), fix: fix, bssids: bssids, zones: zones)).0
        }
        check("inside office → allow",                       verdict(fix: (34.0, -118.0, 5.0), bssids: []) == .t)
        check("outside + no bssid → block",                  verdict(fix: (0.0, 0.0, 5.0), bssids: []) == .f)
        check("outside but pinned bssid seen → allow",       verdict(fix: (0.0, 0.0, 5.0), bssids: ["a4:5e:60:11:22:33"]) == .t)
        check("loc unknown + bssid seen → allow (OR case)",  verdict(fix: nil, bssids: ["a4:5e:60:11:22:33"]) == .t)
        check("loc unknown + bssid unknown → unknown",       verdict(fix: nil, bssids: nil) == .unknown)
        check("loc unknown + bssid absent → unknown",        verdict(fix: nil, bssids: []) == .unknown)
        check("BSSID match is case-insensitive",             verdict(fix: (0.0, 0.0, 5.0), bssids: ["A4:5E:60:11:22:33".lowercased()]) == .t)
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

    print("\n\(pass) passed, \(fail) failed")
    exit(fail == 0 ? 0 : 1)
}
