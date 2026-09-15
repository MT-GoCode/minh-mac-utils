import XCTest
@testable import MacUtilsCore

final class MigrationTests: XCTestCase {
    var dir = ""
    var stateFile: String { dir + "/state.json" }

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "mig-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    func write(_ json: String) { try! json.write(toFile: stateFile, atomically: true, encoding: .utf8) }

    func testKeyOnlyMapMigrates_seqInRequestOrder() {
        write(#"{"pending":{"b.com":{"requestedAt":2,"applyAt":12},"a.com":{"requestedAt":1,"applyAt":11}}}"#)
        let st = DelayQueue.QStateStore.file(stateFile, legacyDecode: Legacy.keyOnlyMap()).load()
        XCTAssertEqual(st.pending["a.com"]?.seq, 0)       // earlier request → lower seq
        XCTAssertEqual(st.pending["b.com"]?.seq, 1)
        XCTAssertEqual(st.pending["a.com"]?.payload, "a.com")   // payload := key synthesized
        XCTAssertEqual(st.nextSeq, 2)
    }
}
