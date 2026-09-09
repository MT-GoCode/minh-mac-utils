import XCTest
@testable import DemonlockCore

final class ZoneOpsTests: XCTestCase {
    func z(_ name: String, r: Double = 100) -> Zone { Zone(name: name, shape: .circle(centerLat: 1, centerLon: 1, radius: r)) }
    func addOp(_ name: String, r: Double = 100) -> (String, String) {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let payload = String(data: try! enc.encode(ZoneOp(op: "add", zone: z(name, r: r))), encoding: .utf8)!
        return ("add:\(name)", payload)
    }
    func delOp(_ name: String) -> (String, String) {
        let payload = String(data: try! JSONEncoder().encode(ZoneOp(op: "del", name: name)), encoding: .utf8)!
        return ("del:\(name)", payload)
    }

    func testKeyAndQueueValidation() {
        XCTAssertEqual(ZoneOps.key(addOp("home").1), "add:home")
        XCTAssertEqual(ZoneOps.key(delOp("home").1), "del:home")
        XCTAssertNil(ZoneOps.key("not json"))
        XCTAssertTrue(ZoneOps.validateAtQueue(addOp("home").1))
        XCTAssertFalse(ZoneOps.validateAtQueue(addOp("home", r: 0).1))        // bad geometry
        XCTAssertFalse(ZoneOps.validateAtQueue(#"{"op":"del","name":"a\nb"}"#)) // newline in name
        XCTAssertFalse(ZoneOps.validateAtQueue(#"{"op":"del","name":""}"#))
    }

    func testMoveEditLands_policyReferenced() {
        // THE bug this project exists for: edit a policy-referenced zone via del+add, both land.
        let live = [z("home")]
        let policy = #"LOCATED_IN_ANY(["home"])"#
        let (d, a) = (delOp("home"), addOp("home", r: 250))
        let r = ZoneOps.fold(due: [d, a], live: live, livePolicy: policy, liveGatePolicy: nil,
                             duePolicyDoc: nil, dueGateDoc: nil)
        XCTAssertNotNil(r.final)
        XCTAssertEqual(r.verdicts["del:home"]?.ok, true)
        XCTAssertEqual(r.verdicts["add:home"]?.ok, true)
        if case .circle(_, _, let radius) = r.final!.first(where: { $0.name == "home" })!.shape {
            XCTAssertEqual(radius, 250)                                        // the move landed
        } else { XCTFail() }
    }

    func testPerOpPreconditionDrops_siblingsProceed() {
        let live = [z("home")]
        let r = ZoneOps.fold(due: [addOp("home"),            // collision → dropped
                                   addOp("bad", r: 0),       // bad geometry → dropped
                                   delOp("ghost"),           // no such zone → no-op drop
                                   addOp("cafe")],           // fine
                             live: live, livePolicy: nil, liveGatePolicy: nil,
                             duePolicyDoc: nil, dueGateDoc: nil)
        XCTAssertEqual(r.verdicts["add:home"]?.reason, "name exists")
        XCTAssertEqual(r.verdicts["add:bad"]?.reason, "bad geometry")
        XCTAssertEqual(r.verdicts["del:ghost"]?.reason, "no such zone (no-op)")
        XCTAssertEqual(r.verdicts["add:cafe"]?.ok, true)
        XCTAssertEqual(r.final?.map(\.name).sorted(), ["cafe", "home"])
    }

    func testWholeBatchDropNamesOrphanedReference() {
        let live = [z("home")]
        let policy = #"NOT LOCATED_IN_ANY(["home"])"#
        let r = ZoneOps.fold(due: [delOp("home")], live: live, livePolicy: policy, liveGatePolicy: nil,
                             duePolicyDoc: nil, dueGateDoc: nil)
        XCTAssertNil(r.final)
        XCTAssertTrue(r.verdicts["del:home"]!.reason!.contains("\"home\""))    // names the reference
    }

    func testPreexistingDanglingReferenceDoesNotBlock() {
        // The real machine: live policy references "451 niantic ave" which isn't in zones.json.
        let live = [z("home")]
        let policy = #"LOCATED_IN_ANY(["home"]) AND NOT LOCATED_IN_ANY(["451 niantic ave"])"#
        let r = ZoneOps.fold(due: [addOp("cafe")], live: live, livePolicy: policy, liveGatePolicy: nil,
                             duePolicyDoc: nil, dueGateDoc: nil)
        XCTAssertNotNil(r.final)                                               // differential: not blocked
        XCTAssertEqual(r.verdicts["add:cafe"]?.ok, true)
    }

    func testAddZonePlusReferencingDueDocBothWork() {
        let live = [z("home")]
        let dueDoc = #"LOCATED_IN_ANY(["cafe"])"#                              // references the zone being added
        let r = ZoneOps.fold(due: [addOp("cafe")], live: live, livePolicy: #"LOCATED_IN_ANY(["home"])"#,
                             liveGatePolicy: nil, duePolicyDoc: dueDoc, dueGateDoc: nil)
        XCTAssertNotNil(r.final)                                               // projection resolves
        XCTAssertEqual(r.verdicts["add:cafe"]?.ok, true)
    }

    func testDelZoneVsDueDocReferencingIt_docWins() {
        let live = [z("home"), z("cafe")]
        let dueDoc = #"LOCATED_IN_ANY(["cafe"])"#                              // valid against LIVE zones
        let r = ZoneOps.fold(due: [delOp("cafe")], live: live, livePolicy: #"LOCATED_IN_ANY(["home"])"#,
                             liveGatePolicy: nil, duePolicyDoc: dueDoc, dueGateDoc: nil)
        XCTAssertNil(r.final)                                                  // batch dropped, doc lands
        XCTAssertEqual(r.verdicts["del:cafe"]?.reason, "conflicts with landing policy")
    }

    func testDueDocBrokenAgainstLiveToo_batchRetriesAgainstLiveDocs() {
        let live = [z("home"), z("cafe")]
        let dueDoc = #"LOCATED_IN_ANY(["never-existed"])"#                     // broken vs live as well
        let r = ZoneOps.fold(due: [delOp("cafe")], live: live, livePolicy: #"LOCATED_IN_ANY(["home"])"#,
                             liveGatePolicy: nil, duePolicyDoc: dueDoc, dueGateDoc: nil)
        XCTAssertNotNil(r.final)                                               // live policy doesn't reference cafe
        XCTAssertEqual(r.verdicts["del:cafe"]?.ok, true)
    }

    func testGatePolicyReferencesCountToo() {
        let live = [z("home"), z("cafe")]
        let gate = #"IN_POLICY AND LOCATED_IN_ANY(["cafe"])"#
        let r = ZoneOps.fold(due: [delOp("cafe")], live: live, livePolicy: nil, liveGatePolicy: gate,
                             duePolicyDoc: nil, dueGateDoc: nil)
        XCTAssertNil(r.final)                                                  // gate reference protects it
    }
}
