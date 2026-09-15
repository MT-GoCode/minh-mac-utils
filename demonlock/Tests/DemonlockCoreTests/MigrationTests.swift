import XCTest
import MacUtilsCore
@testable import DemonlockCore

final class MigrationTests: XCTestCase {
    var dir = ""
    var stateFile: String { dir + "/state.json" }

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "mig-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    func write(_ json: String) { try! json.write(toFile: stateFile, atomically: true, encoding: .utf8) }

    func testSingleSlotPolicyMigrates() {
        // byte-exact legacy DelayedState shape (DelayedChange.swift)
        write(#"{"pending":{"payload":"TIME_IS_ANY([*0400-2300])","requestedAt":100,"applyAt":129700},"lastAppliedAt":50}"#)
        let st = DelayQueue.QStateStore.file(stateFile, legacyDecode: Legacy.singleSlot(constKey: "policy")).load()
        XCTAssertEqual(st.pending["policy"]?.payload, "TIME_IS_ANY([*0400-2300])")
        XCTAssertEqual(st.pending["policy"]?.applyAt, 129700)
        XCTAssertEqual(st.lastAppliedAt, 50)
        XCTAssertEqual(st.nextSeq, 1)                     // strictly above migrated seq 0
    }

    func testZonesLegacyPendingDroppedAndLastAppliedKept() {
        write(#"{"pending":{"payload":"[…snapshot…]","requestedAt":1,"applyAt":2},"lastAppliedAt":1788911873.5}"#)
        let st = DelayQueue.QStateStore.file(stateFile, legacyDecode: Legacy.zonesDropSnapshot()).load()
        XCTAssertTrue(st.pending.isEmpty)                 // snapshot dropped, logged
        XCTAssertEqual(st.lastAppliedAt, 1788911873.5)
    }

    func testSafeAppsMigrates() {
        write(#"{"pending":{"raycast":{"app":{"name":"raycast","bid":"com.raycast.macos","tid":"T123","rootOwned":false},"requestedAt":10,"applyAt":20}}}"#)
        let st = DelayQueue.QStateStore.file(stateFile, legacyDecode: Legacy.safeApps()).load()
        let item = st.pending["raycast"]
        XCTAssertNotNil(item)
        let app = try? JSONDecoder().decode(SafeApp.self, from: Data(item!.payload.utf8))
        XCTAssertEqual(app?.bid, "com.raycast.macos")
        XCTAssertEqual(app?.rootOwned, false)             // the flag survives, byte-canonical
        XCTAssertEqual(item?.applyAt, 20)
    }

    func testNextSeqAboveAllMigrated() {
        // hand-written new-shape state with a bad nextSeq — load must fix it up
        write(#"{"pending":{"k":{"payload":"p","requestedAt":1,"applyAt":2,"seq":7}},"nextSeq":3,"recent":[]}"#)
        let st = DelayQueue.QStateStore.file(stateFile).load()
        XCTAssertEqual(st.nextSeq, 8)
    }

    func testNewShapeRoundTripsUntouched() {
        let st0 = DelayQueue.QState(pending: ["k": .init(payload: "p", requestedAt: 1, applyAt: 2, seq: 0)],
                                    nextSeq: 1, lastAppliedAt: 9,
                                    recent: [.init(key: "k", what: "queued", reason: nil, at: 1)])
        let store = DelayQueue.QStateStore.file(stateFile, legacyDecode: Legacy.singleSlot(constKey: "x"))
        store.save(st0)
        let st1 = store.load()
        XCTAssertEqual(st1.pending, st0.pending)
        XCTAssertEqual(st1.recent, st0.recent)
        XCTAssertEqual(st1.lastAppliedAt, 9)
    }

    func testCorruptFileYieldsEmptyQState() {
        write("not json at all {{{")
        let st = DelayQueue.QStateStore.file(stateFile, legacyDecode: Legacy.singleSlot(constKey: "x")).load()
        XCTAssertTrue(st.pending.isEmpty)                 // fail-closed, like loadJSON everywhere
    }

    func testDowngradeDecodeFailsClosed() {
        // Test-local byte-copy of the OLD DelayedState struct: it must FAIL to decode new-shape
        // JSON (pending is a map, not an object) and fall back to empty — proving the spec's
        // downgrade direction: queued loosenings vanish, nothing lands early.
        struct OldPendingChange: Codable { var payload: String; var requestedAt: Double; var applyAt: Double }
        struct OldDelayedState: Codable { var pending: OldPendingChange?; var lastAppliedAt: Double? }
        let newShape = #"{"pending":{"k":{"payload":"p","requestedAt":1,"applyAt":2,"seq":0}},"nextSeq":1,"recent":[]}"#
        let decoded = try? JSONDecoder().decode(OldDelayedState.self, from: Data(newShape.utf8))
        XCTAssertNil(decoded)                             // old binary sees nil → empty state → clobber
    }
}
