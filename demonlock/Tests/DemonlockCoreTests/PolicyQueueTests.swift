import XCTest
import MacUtilsCore
@testable import DemonlockCore

final class PolicyQueueTests: XCTestCase {
    var dir = ""
    var uid: uid_t { getuid() }
    func q() -> DelayQueue {
        DelayQueue(kind: "policy", store: .file(dir + "/st.json", legacyDecode: Legacy.singleSlot(constKey: "policy")),
                   requestMarker: dir + "/req", abortMarker: dir + "/abort",
                   onFailure: .drop, payloadIsJSON: false, auditLog: dir + "/audit.log")
    }
    let zones = [Zone(name: "home", shape: .circle(centerLat: 1, centerLon: 1, radius: 100))]

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "pq-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    func testDifferentialAcceptance() {
        // live policy dangles "gone" — a doc keeping that dangle is accepted; a NEW dangle is not
        let baseline = #"LOCATED_IN_ANY(["home"]) AND NOT LOCATED_IN_ANY(["gone"])"#
        XCTAssertTrue(PolicyEngine.acceptsDifferentially(#"NOT LOCATED_IN_ANY(["gone"])"#, zones: zones, baseline: baseline))
        XCTAssertTrue(PolicyEngine.acceptsDifferentially(#"LOCATED_IN_ANY(["home"])"#, zones: zones, baseline: baseline))
        XCTAssertFalse(PolicyEngine.acceptsDifferentially(#"LOCATED_IN_ANY(["brand-new"])"#, zones: zones, baseline: baseline))
        XCTAssertFalse(PolicyEngine.acceptsDifferentially("not a policy ((", zones: zones, baseline: baseline))
        XCTAssertFalse(PolicyEngine.acceptsDifferentially("IN_POLICY", zones: zones, baseline: nil))       // main policy: no IN_POLICY
        XCTAssertTrue(PolicyEngine.acceptsDifferentially("IN_POLICY", zones: zones, baseline: nil, allowInPolicy: true))
    }

    func testConstantKeyReplaceResetsAndMultiLineRoundTrips() {
        let queue = q()
        let doc1 = "LOCATED_IN_ANY([\"home\"])\nAND TIME_IS_ANY([*0400-2300])"       // multi-line, legal today
        let validate: (String) -> Bool = { PolicyEngine.acceptsDifferentially($0, zones: self.zones, baseline: nil) }
        _ = MarkerIO.append(dir + "/req", line: doc1)
        _ = queue.consumeMarkers(now: 1000, enforcedUID: uid, delaySec: { _ in 100 }, key: { _ in "policy" }, validate: validate)
        XCTAssertEqual(queue.status().rows.count, 1)
        // identical resubmit (shell repeat) — idempotent, clock kept
        _ = MarkerIO.append(dir + "/req", line: doc1)
        _ = queue.consumeMarkers(now: 1050, enforcedUID: uid, delaySec: { _ in 100 }, key: { _ in "policy" }, validate: validate)
        XCTAssertEqual(queue.status().rows[0].applyAt, 1100)
        // different doc — replace + reset
        _ = MarkerIO.append(dir + "/req", line: #"TIME_IS_ANY([*0400-2300])"#)
        _ = queue.consumeMarkers(now: 1060, enforcedUID: uid, delaySec: { _ in 100 }, key: { _ in "policy" }, validate: validate)
        XCTAssertEqual(queue.status().rows.count, 1)
        XCTAssertEqual(queue.status().rows[0].applyAt, 1160)
        // landing applies the doc verbatim (incl. the newline had it survived — assert round-trip shape)
        var landed: String? = nil
        _ = queue.applyDue(now: 2000, validate: validate) { due in
            landed = due[0].payload
            return [due[0].key: (true, nil)]
        }
        XCTAssertEqual(landed, #"TIME_IS_ANY([*0400-2300])"#)
    }

    func testMultiLineDocSurvivesMarkerFraming() {
        let doc = "LOCATED_IN_ANY([\"home\"])\nAND\nTIME_IS_ANY([*0400-2300])"
        _ = MarkerIO.append(dir + "/req", line: doc)
        XCTAssertEqual(MarkerIO.consumeLines(dir + "/req", enforcedUID: uid), [doc])   // one payload, newlines intact
        XCTAssertNotNil(try? PolicyEngine.validate(doc, zones: zones))                  // and it parses
    }
}
