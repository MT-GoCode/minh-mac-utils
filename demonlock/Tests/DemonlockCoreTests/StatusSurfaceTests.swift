import XCTest
@testable import DemonlockCore

final class StatusSurfaceTests: XCTestCase {
    func testStateSnapshotDecodesOldShape() throws {
        // A pre-upgrade daemon's state.json: old DelayedStatus OBJECT under the key the new
        // QStatus field now owns. Synthesized Codable would THROW on the type mismatch and blank
        // the whole snapshot ("enforcer isn't running"); the lenient init must decode core fields
        // and nil the mismatched one instead.
        let legacy = """
        {"updatedEpoch":1,"lastCheckEpoch":1,"armed":true,"enforcedUser":"minh","phase":"snoozed",
         "reason":"r","countdownSeconds":10,"pollSeconds":1,"policyString":"p","insideZones":[],
         "health":{"agentFeedFresh":false,"locState":"ok","needsPermAsk":false,"locationTrail":[]},
         "delayedPolicy":{"kind":"policy","pending":true,"applyAtEpoch":5,"payloadPreview":"x","lastAppliedEpoch":2},
         "safeApps":{"pending":[{"name":"a","bid":"b","applyAtEpoch":3}]}}
        """
        let snap = try JSONDecoder().decode(StateSnapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(snap.enforcedUser, "minh")          // core fields intact
        XCTAssertEqual(snap.phase, "snoozed")
        XCTAssertNil(snap.delayedPolicy)                   // mismatched old shapes → nil, not throw
        XCTAssertNil(snap.safeApps)
    }

    func testPrintQueueStatusRendersRowsAbortAndLastLanded() {
        let q = DelayQueue.QStatus(
            kind: "zones",
            rows: [.init(key: "add:730 moreno", preview: "{...}", applyAt: nowEpoch() + 7200, seq: 0)],
            lastAppliedAt: nowEpoch() - 3600,
            recent: [.init(key: "del:office", what: "rejected", reason: "name exists", at: nowEpoch() - 60)],
            full: false)
        let out = queueStatusLines("zones", q, abortCmd: "demonlock delayzones --abort")!
        XCTAssertTrue(out.contains("add:730 moreno"))
        XCTAssertTrue(out.contains("lands"))
        XCTAssertTrue(out.contains(#"demonlock delayzones --abort "add:730 moreno""#))
        XCTAssertTrue(out.contains("REJECTED"))
        XCTAssertTrue(out.contains("last landed"))
    }
}
